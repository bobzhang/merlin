open Std
open Raw_parser

let rollbacks parser =
  let stacks =
    let l = List.Lazy.unfold Merlin_parser.pop parser in
    List.Lazy.Cons (parser, lazy l)
  in
  let last_loc = ref None in
  let recoverable =
    List.Lazy.filter_map
      (fun t ->
         let location = !last_loc in
         last_loc := Some (Merlin_parser.location t);
         Merlin_parser.recover ?location t
      ) stacks
  in
  let last_pos = ref (-1) in
  let recoverable =
    List.Lazy.filter_map
      (fun t ->
         let start = snd (Lexing.split_pos t.Location.loc.Location.loc_start) in
         if start = !last_pos
         then None
         else (last_pos := start; Some t)
      ) recoverable
  in
  recoverable

type t = {
  errors: exn list;
  parser: Merlin_parser.t;
  recovering: (Merlin_parser.t Location.loc list *
               Merlin_parser.t Location.loc List.Lazy.t) option;
}

let parser t = t.parser
let exns t = t.errors

let fresh parser = { errors = []; parser; recovering = None }

let feed_normal (_,tok,_ as input) parser =
  Logger.debugf `internal
    (fun ppf tok -> Format.fprintf ppf "normal parser: received %s"
        (Merlin_parser.Values.Token.to_string tok))
    tok;
  match Merlin_parser.feed input parser with
  | `Accept _ ->
    Logger.debug `internal "parser accepted";
    Some parser
  | `Reject _ ->
    Logger.debug `internal "parser rejected";
    None
  | `Step parser ->
    Some parser

let closing_token = function
  | END -> true
  | _ -> false

let feed_recover original (s,tok,e as input) (hd,tl) =
  let get_col x = snd (Lexing.split_pos x) in
  let col = get_col s in
  (* Find appropriate recovering position *)
  let rec to_the_right hd tl =
    match hd with
    | cell :: hd' when col > get_col cell.Location.loc.Location.loc_start ->
      to_the_right hd' (List.Lazy.Cons (cell, Lazy.from_val tl))
    | _ -> hd, tl
  in
  let rec to_the_left hd tl =
    match tl with
    | List.Lazy.Cons (cell, lazy tl)
      when get_col cell.Location.loc.Location.loc_start > col ->
      to_the_left (cell :: hd) tl
    | _ -> hd, tl
  in
  let hd, tl = to_the_right hd tl in
  let hd, tl = to_the_left hd tl in
  (* Closing tokens are applied one step behind *)
  let hd, tl =
    match closing_token tok, hd with
    | true, (x :: hd) -> hd, List.Lazy.Cons (x, lazy tl)
    | _ -> hd, tl
  in
  match hd, tl with
  | [], List.Lazy.Nil -> assert false
  | _, List.Lazy.Cons (cell, _) | (cell :: _), _ ->
    let candidate = cell.Location.txt in
    match Merlin_parser.feed input candidate with
    | `Accept _ | `Reject _ ->
      Either.L (hd,tl)
    | `Step parser ->
      let diff = Merlin_reconstruct.diff ~stack:original ~wrt:parser in
      match Merlin_parser.reconstruct
              (Merlin_reconstruct.Partial_stack diff)
              candidate
      with
      | None -> assert false
      | Some parser ->
        match Merlin_parser.feed input parser with
        | `Accept _ | `Reject _ -> assert false
        | `Step parser -> Either.R parser

let fold warnings token t =
  match token with
  | Merlin_lexer.Error _ -> t
  | Merlin_lexer.Valid (s,tok,e) ->
    Logger.debugf `internal
      (fun ppf tok -> Format.fprintf ppf "received %s"
          (Merlin_parser.Values.Token.to_string tok))
      tok;
    Logger.debugf `internal Merlin_parser.dump t.parser;
    warnings := [];
    let pop w = let r = !warnings in w := []; r in
    let recover_from t recovery =
      match feed_recover t.parser (s,tok,e) recovery with
      | Either.L recovery ->
        {t with recovering = Some recovery}
      | Either.R parser ->
        {t with parser; recovering = None}
    in
    match t.recovering with
    | Some recovery -> recover_from t recovery
    | None ->
      begin match feed_normal (s,tok,e) t.parser with
        | None ->
          let recovery = ([], rollbacks t.parser) in
          let error =
            Error_classifier.from (Merlin_parser.to_step t.parser) (s,tok,e)
          in
          recover_from
            {t with errors = error :: (pop warnings) @ t.errors; }
            recovery
        | Some parser ->
          {t with errors = (pop warnings) @ t.errors; parser }
      end

let fold token t =
  let warnings = ref [] in
  Either.get (Parsing_aux.catch_warnings warnings
                (fun () -> fold warnings token t))

let dump_snapshot ppf s =
  Format.fprintf ppf "- position: %a\n  parser: %a\n"
    Location.print s.Location.loc
    Merlin_parser.dump s.Location.txt

let dump_recovering ppf = function
  | None -> Format.fprintf ppf "clean"
  | Some (head, tail) ->
    let tail = List.Lazy.to_strict tail in
    let iter ppf l = List.iter ~f:(dump_snapshot ppf) l in
    Format.fprintf ppf "recoverable states\nhead:\n%atail:\n%a"
      iter head
      iter tail

let dump ppf t =
  Format.fprintf ppf "parser: %a\n" Merlin_parser.dump t.parser;
  Format.fprintf ppf "recovery: %a\n" dump_recovering t.recovering

let dump_recoverable ppf t =
  let t = match t.recovering with
    | Some _ -> t
    | None -> {t with recovering = Some ([], rollbacks t.parser)}
  in
  dump ppf t
