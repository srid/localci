type manifest_entry = {
  key : string;
  step : string;
  system : string;
  log_file : string;
}

let sanitize_log_name name =
  let buf = Buffer.create (String.length name) in
  let last_was_dash = ref false in
  String.iter
    (fun c ->
      match c with
      | '/' | ' ' | '(' | ')' ->
        if not !last_was_dash then Buffer.add_char buf '-';
        last_was_dash := true
      | _ ->
        Buffer.add_char buf c;
        last_was_dash := false)
    name;
  let s = Buffer.contents buf in
  let len = String.length s in
  let end_pos = ref (len - 1) in
  while !end_pos >= 0 && s.[!end_pos] = '-' do
    decr end_pos
  done;
  if !end_pos < 0 then "" else String.sub s 0 (!end_pos + 1)

let write_manifest log_dir entries =
  let json =
    `List
      (List.map
         (fun e ->
           let fields =
             [ ("key", `String e.key);
               ("step", `String e.step);
               ("log_file", `String e.log_file) ]
           in
           let fields =
             if e.system <> "" then
               fields @ [ ("system", `String e.system) ]
             else fields
           in
           `Assoc fields)
         entries)
  in
  let path = Filename.concat log_dir "manifest.json" in
  let oc = open_out path in
  Yojson.Safe.pretty_to_channel oc json;
  output_char oc '\n';
  close_out oc

let load_manifest log_dir =
  let path = Filename.concat log_dir "manifest.json" in
  try
    let json = Yojson.Safe.from_file path in
    let open Yojson.Safe.Util in
    to_list json
    |> List.map (fun e ->
         {
           key = member "key" e |> to_string;
           step = member "step" e |> to_string;
           system =
             (match member "system" e with
              | `String s -> s
              | _ -> "");
           log_file = member "log_file" e |> to_string;
         })
  with _ -> []

let string_contains haystack needle =
  let hlen = String.length haystack and nlen = String.length needle in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec loop i =
      if i > hlen - nlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

type step_result = {
  step : string;
  system : string;
  failed : bool;
  messages : string list;
}

let load_step_results log_dir =
  let entries = load_manifest log_dir in
  List.map
    (fun e ->
      let messages = ref [] in
      let failed = ref false in
      (try
         let ic = open_in e.log_file in
         (try
            while true do
              let line = input_line ic in
              (try
                 let json = Yojson.Safe.from_string line in
                 match Yojson.Safe.Util.member "message" json with
                 | `String m ->
                   messages := m :: !messages;
                   if string_contains m "failed" then failed := true
                 | _ -> ()
               with _ -> ())
            done
          with End_of_file -> ());
         close_in ic
       with _ -> ());
      {
        step = e.step;
        system = e.system;
        failed = !failed;
        messages = List.rev !messages;
      })
    entries

let print_step_report log_dir =
  let results = load_step_results log_dir in
  if results = [] then ()
  else begin
    let has_systems =
      List.exists (fun r -> r.system <> "") results
    in
    Printf.eprintf "\n%!";
    (* Compute column widths *)
    let step_w =
      List.fold_left
        (fun acc r -> max acc (String.length r.step))
        4 (* "Step" *) results
    in
    let sys_w =
      if has_systems then
        List.fold_left
          (fun acc r -> max acc (String.length r.system))
          6 (* "System" *) results
      else 0
    in
    (* Header *)
    if has_systems then
      Printf.eprintf "%s  %s  %s\n%!" (Log.bold (Printf.sprintf "%-*s" step_w "Step"))
        (Log.bold (Printf.sprintf "%-*s" sys_w "System"))
        (Log.bold "Status")
    else
      Printf.eprintf "%s  %s\n%!" (Log.bold (Printf.sprintf "%-*s" step_w "Step"))
        (Log.bold "Status");
    (* Rows *)
    List.iter
      (fun r ->
        let status =
          if r.failed then Log.red_bold "FAIL" else Log.green "pass"
        in
        if has_systems then
          Printf.eprintf "%-*s  %-*s  %s\n%!" step_w r.step sys_w r.system
            status
        else Printf.eprintf "%-*s  %s\n%!" step_w r.step status)
      results;
    (* Tail of failed step output *)
    let tail_lines = 20 in
    List.iter
      (fun r ->
        if r.failed then begin
          let label =
            if r.system <> "" then
              Printf.sprintf "%s (%s)" r.step r.system
            else r.step
          in
          Printf.eprintf "\n%!";
          Log.warn "%s:" (Log.bold label);
          let n = List.length r.messages in
          let start = max 0 (n - tail_lines) in
          if start > 0 then
            Log.info "... (%d lines omitted)" start;
          let msgs = ref r.messages in
          let i = ref 0 in
          while !i < start do
            msgs := List.tl !msgs;
            incr i
          done;
          List.iter
            (fun m -> Printf.eprintf "    %s\n%!" m)
            !msgs
        end)
      results
  end
