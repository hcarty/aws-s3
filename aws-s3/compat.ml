type 'a deferred = 'a
module Deferred = struct
  open Core
  type 'a t = 'a deferred

  module Or_error = struct
    type nonrec 'a t = 'a Or_error.t
    let return = Or_error.return
    let fail e = Result.Error e
    let catch f = Or_error.try_with_join f

    module Infix = struct
      let (>>=) a b =
        match a with
        | Ok v -> b v
        | Error _ as e -> e
    end
  end

  module Infix = struct
    let (>>=) a b = b a
    let (>>|) a b = b a
    let (>>=?) = Or_error.Infix.(>>=)
  end

  let return a = a
  let after delay = Unix.nanosleep delay |> ignore
  let catch f = Core.Or_error.try_with f
end

module Cohttp_deferred = struct
  module Body = struct
    type t = Cohttp.Body.t
    let to_string = Cohttp.Body.to_string
    let of_string = Cohttp.Body.of_string
  end

  module Client = struct
    let request ?body:_ _request = failwith "Not implemented"
  end
end
