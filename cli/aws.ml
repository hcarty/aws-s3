open Core
(* We need to make a functor over deferred *)
module Make(Compat: Aws_s3.Types.Compat) = struct
  module S3 = Aws_s3.S3.Make(Compat)
  module Credentials = Aws_s3.Credentials.Make(Compat)
  open Compat
  open Compat.Deferred
  open Compat.Deferred.Infix

  let read_file ?first ?last file =
    let data = Core.In_channel.(with_file file ~f:input_all) in
    let len = String.length data in
    match (first, last) with
    | None, None -> data
    | first, last ->
      let first = Option.value ~default:0 first in
      let last = Option.value ~default:(len - 1) last in
      String.sub ~pos:first ~len:(last - first + 1) data

  let save_file file contents =
    Core.Out_channel.(with_file file ~f:(fun c -> output_string c contents))

  type objekt = { bucket: string; key: string }
  let objekt_of_uri u = { bucket = (Option.value_exn ~message:"No Host in uri" (Uri.host u));
                          key = String.drop_prefix (Uri.path u) 1 (* Remove the beginning '/' *) }


  let string_of_error = function
    | S3.Redirect _ -> "Redirect"
    | S3.Throttled -> "Throttled"
    | S3.Unknown (code, msg) -> sprintf "Unknown: %d, %s" code msg
    | S3.Not_found -> "Not_found"
    | S3.Exn exn -> sprintf "Exn: %s" (Exn.to_string exn)

  type cmd =
    | S3toLocal of objekt * string
    | LocaltoS3 of string * objekt

  let retry ~delay ~retries ~(f : (?region:Aws_s3.Util.region -> unit -> ('a, 'b) result Deferred.t)) () : ('a, 'b) result Deferred.t =
    let rec inner ?region ~retries () =
      f ?region () >>= function
      | Error (S3.Redirect region) ->
        inner ~region ~retries ()
      | Error e ->
        Caml.Printf.eprintf "Error. Retry %s\n%!" (string_of_error e);
        after delay >>= fun () -> inner ?region ~retries:(retries - 1) ()
      | Ok r -> return (Ok r)
    in
    inner ~retries ()


  let determine_paths src dst =
    let src = Uri.of_string src in
    let dst = Uri.of_string dst in
    let is_s3 u = Uri.scheme u = Some "s3" in
    match is_s3 src, is_s3 dst with
    | (true, false) -> S3toLocal (objekt_of_uri src, Uri.path dst)
    | (false, true) -> LocaltoS3 (Uri.path src, objekt_of_uri dst)
    | (false, false) -> failwith "Use cp(1)"
    | (true, true) -> failwith "Does not support copying from s3 to s3"

  let cp profile ?first ?last src dst =
    let range = { S3.first; last } in
    Credentials.Helper.get_credentials ?profile () >>= fun credentials ->
    let credentials = Core.Or_error.ok_exn credentials in
    (* nb client does not support preflight 100 *)
    match determine_paths src dst with
    | S3toLocal (src, dst) ->
        S3.get ~credentials ~range ~bucket:src.bucket ~key:src.key () >>=? fun data ->
        save_file dst data;
        Deferred.return (Ok ())
    | LocaltoS3 (src, dst) ->
      let data = read_file ?first ?last src in
      S3.put ~credentials ~bucket:dst.bucket ~key:dst.key data >>=? fun _etag ->
      Deferred.return (Ok ())

  let rm profile bucket paths =
    Credentials.Helper.get_credentials ?profile () >>= fun credentials ->
    let credentials = Core.Or_error.ok_exn credentials in
    match paths with
    | [ key ] ->
        S3.delete ~credentials ~bucket ~key ()
    | keys ->
      let objects : S3.Delete_multi.objekt list = List.map ~f:(fun key -> { S3.Delete_multi.key; version_id = None }) keys in
      S3.delete_multi ~credentials ~bucket objects () >>=? fun _deleted ->
      Deferred.return (Ok ())

  let ls profile ratelimit bucket prefix =
    let ratelimit_f = match ratelimit with
      | None -> fun () -> Deferred.return (Ok ())
      | Some n -> fun () -> after (1000. /. float n) >>= fun () -> Deferred.return (Ok ())
    in
    let rec ls_all (result, cont) =
      Core.List.iter ~f:(fun { last_modified;  S3.Ls.key; size; etag; _ } -> Caml.Printf.printf "%s\t%d\t%s\t%s\n%!" (Time.to_string last_modified) size key (Caml.Digest.to_hex etag)) result;

      match cont with
      | S3.Ls.More continuation -> ratelimit_f ()
        >>=? retry ~retries:5 ~delay:1.0 ~f:(fun ?region:_ () -> continuation ())
        >>=? ls_all
      | S3.Ls.Done -> Deferred.return (Ok ())
    in
    Credentials.Helper.get_credentials ?profile () >>= fun credentials ->
    let credentials = Core.Or_error.ok_exn credentials in
    retry ~retries:5 ~delay:1.0 ~f:(fun ?region () -> S3.ls ?region ~credentials ?prefix ~bucket ()) () >>=? ls_all
  let exec ({ Cli.profile }, cmd) =
    begin
      match cmd with
      | Cli.Cp { src; dest; first; last } ->
        cp profile ?first ?last src dest
      | Rm { bucket; paths }->
        rm profile bucket paths
      | Ls { ratelimit; bucket; prefix } ->
        ls profile ratelimit bucket prefix
    end >>= function
    | Ok _ -> return 0
    | Error _ ->
      Printf.eprintf "Error\n%!";
      return 1
end
