module Q = Queue
open Amqp_thread
open Amqp_spec

type no_confirm = [ `Ok ]
type with_confirm = [ `Ok | `Failed ]


type _ confirms =
  | No_confirm: no_confirm confirms
  | With_confirm: with_confirm confirms

let no_confirm = No_confirm
let with_confirm = With_confirm

type consumer = Basic.Deliver.t * Basic.Content.t * string -> unit
type consumers = (string, consumer) Hashtbl.t

type publish_confirm = { mutable message_count: int;
                         unacked: (int * [ `Ok | `Failed ] Ivar.t) Q.t }

type _ pcp =
  | Pcp_no_confirm: no_confirm pcp
  | Pcp_with_confirm: publish_confirm -> with_confirm pcp

type 'a t = { framing: Amqp_framing.t;
              channel_no: int;
              consumers: consumers;
              id: string;
              mutable counter: int;
              publish_confirm: 'a pcp;
            }

let channel { framing; channel_no; _ } = (framing, channel_no)

module Internal = struct
  let next_counter t =
    t.counter <- t.counter + 1;
    t.counter

  let unique_id t =
    Printf.sprintf "%s.%d" t.id (next_counter t)

  let register_deliver_handler t =
    let open Basic in
    let handler (deliver, (content, data)) =
      try
        let handler = Hashtbl.find t.consumers deliver.Deliver.consumer_tag in
        handler (deliver, content, data);
      (* Keep the current handler *)
      with
      | Not_found -> failwith ("No consumers for: " ^ deliver.Deliver.consumer_tag)
    in
    let read = snd Deliver.Internal.read in
    read ~once:false handler (channel t)

  let register_consumer_handler t consumer_tag handler =
    if Hashtbl.mem t.consumers consumer_tag then raise Amqp_types.Busy;
    Hashtbl.add t.consumers consumer_tag handler

  let deregister_consumer_handler t consumer_tag =
    Hashtbl.remove t.consumers consumer_tag

  let wait_for_confirm: type a. a t -> a Deferred.t = fun t ->
    match t.publish_confirm with
    | Pcp_with_confirm t ->
      let var = Ivar.create () in
      let id = t.message_count + 1 in
      t.message_count <- id;
      Q.add (id, var) t.unacked;
      (Ivar.read var : [`Ok | `Failed] Deferred.t)
    | Pcp_no_confirm -> return `Ok
end

let close_handler channel_no close =
  Printf.eprintf "Channel closed: %d\n" channel_no;
  Printf.eprintf "Reply code: %d\n" close.Channel.Close.reply_code;
  Printf.eprintf "Reply text: %s\n" close.Channel.Close.reply_text;
  Printf.eprintf "Message: (%d, %d)\n" close.Channel.Close.class_id close.Channel.Close.method_id;
  raise (Amqp_types.Channel_closed channel_no)

let register_flow_handler t =
  let (_, read) = Channel.Flow.Internal.read in
  let handler { Channel.Flow.active } =
    Amqp_framing.set_flow t.framing t.channel_no active;
    spawn (Channel.Flow_ok.Internal.write (channel t) { Channel.Flow_ok.active })
  in
  read ~once:false handler (channel t)

let handle_confirms channel t =

  let confirm multiple =
    let confirm_single s tag =
      let tmp = Q.create () in
      let rec inner () =
        match Q.take t.unacked with
        | (id, _) as e when id < tag ->
            Q.add e tmp;
            inner ()
        | (id, v) when id = tag ->
            Ivar.fill v s;
        | e ->
            Q.add e tmp;
        | exception Q.Empty ->
            failwith (Printf.sprintf "Unexpected confirm: %d %d"
                        tag
                        (Q.length t.unacked));
            (* Strange. Tag cannot be found *)
      in
      inner ();
      Q.transfer t.unacked tmp;
      Q.transfer tmp t.unacked
    in

    let rec confirm_multiple s tag =
      match Q.peek t.unacked with
      | (id, v) when id <= tag ->
          Ivar.fill v s;
          Q.take t.unacked |> ignore;
          confirm_multiple s tag
      | _ -> ()
      | exception Q.Empty -> ()
    in
    match multiple with
    | true -> confirm_multiple
    | false -> confirm_single
  in


  let open Basic in

  let read_ack = snd Ack.Internal.read in
  let read_reject = snd Reject.Internal.read in
  read_ack ~once:false (fun m -> confirm m.Ack.multiple `Ok m.Ack.delivery_tag) channel;
  read_reject ~once:false (fun m -> confirm false `Ok m.Reject.delivery_tag) channel;
  Confirm.Select.request channel { Confirm.Select.nowait = false }

let create: type a. id:string -> a confirms -> Amqp_framing.t -> Amqp_framing.channel_no -> a t Deferred.t = fun ~id confirm_type framing channel_no ->
  let consumers = Hashtbl.create 0 in
  let id = Printf.sprintf "%s.%s.%d" (Amqp_framing.id framing) id channel_no in
  Amqp_framing.open_channel framing channel_no >>= fun () ->
  spawn (Channel.Close.reply (framing, channel_no) (close_handler channel_no));
  Channel.Open.request (framing, channel_no) () >>= fun () ->
  let publish_confirm : a pcp = match confirm_type with
    | With_confirm ->
        Pcp_with_confirm { message_count = 0; unacked = Q.create () }
    | No_confirm -> Pcp_no_confirm
  in
  (match publish_confirm with Pcp_with_confirm t -> handle_confirms (framing, channel_no) t | Pcp_no_confirm -> return ()) >>= fun () ->
  let t = { framing; channel_no; consumers; id; counter = 0; publish_confirm } in
  Internal.register_deliver_handler t;

  register_flow_handler t;
  return t

let close { framing; channel_no; _ } =
  let open Channel.Close in
  request (framing, channel_no)
    { reply_code=200;
      reply_text="Closed on user request";
      class_id=0;
      method_id=0; } >>= fun () ->
  Amqp_framing.close_channel framing channel_no

let flush t =
  Amqp_framing.flush_channel t.framing t.channel_no

let on_return t =
  let reader, writer = Pipe.create () in
  let (_, read) = Basic.Return.Internal.read in
  read ~once:false (Pipe.write_without_pushback writer) (channel t);
  reader

let id t = t.id

let channel_no t = t.channel_no

let set_prefetch ?(count=0) ?(size=0) t =
  Basic.Qos.request (channel t) { Basic.Qos.prefetch_count=count;
                                  prefetch_size=size;
                                  global=false }

let set_global_prefetch ?(count=0) ?(size=0) t =
  Basic.Qos.request (channel t) { Basic.Qos.prefetch_count=count;
                                  prefetch_size=size;
                                  global=true }

module Transaction = struct
  (** Hmm. Create an exsistential type? *)
  type tx = EChannel: _ t -> tx

  open Amqp_spec.Tx
  let start t =
    Select.request (channel t) () >>= fun () ->
    return (EChannel t)

  let commit (EChannel t) =
    Commit.request (channel t) ()

  let rollback (EChannel t) =
    Rollback.request (channel t) ()
end
