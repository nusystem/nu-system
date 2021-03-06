signature NU_PROCESSOR = sig
  type binding = Binding.binding
  exception Bypass of (thm * Proof.context) option
  exception ProcessTerminated of (thm * Proof.context) * Token.T list
  exception ProcessFail of binding * (thm * Proof.context) * exn
  exception Process_State_Call of Token.T list * (thm * Proof.context) * (Proof.state -> Proof.state)
  exception Process_State_Call' of (thm * Proof.context) * (Proof.state -> Proof.state)
  type proc = (Proof.context -> thm -> (unit -> thm * Proof.context) parser)

  val trace : bool Config.T

  val define : binding -> int (*precedence*) -> term (*pattern*) -> proc -> local_theory -> local_theory
  (* val get : Proof.context -> string -> T option *)
  val defined : Context.generic -> string -> bool
  val get_attr : Context.generic -> xstring * Position.T -> attribute parser
  val enable : string -> Context.generic -> Context.generic
  val disable : string -> Context.generic -> Context.generic
  val list : Context.generic -> (binding * term (*pattern*)) list
  val internal_process : thm -> Proof.context -> (thm * Proof.context) parser
  val simple_process : thm -> Proof.context -> (thm * Proof.context) parser
  val powerful_process : Token.T list -> Proof.state -> Proof.state
  val process_by_input : Token.T list -> thm -> Proof.context -> thm * Proof.context
  val process_no_input : thm -> Proof.context -> thm * Proof.context
  val process_attr : attribute parser

  (* be activated only when auto level >= 1 *)
  val almost_safe : (Proof.context -> 'a) -> Proof.context -> 'a
  (* be activated only when auto level >= 2 *)
  val not_safe : (Proof.context -> 'a) -> Proof.context -> 'a
  val apply_attr : Proof.context -> thm -> attribute -> thm
  val parse_auto_level : proc -> proc

  val setup : binding -> int (*precedence*) -> term (*pattern*) -> proc ->
        string (*comment*) -> local_theory -> local_theory
  val setup' : binding -> int (*precedence*) ->
        (string (*pattern*) * (binding * string option * mixfix) list) -> proc ->
        string (*comment*) -> local_theory -> local_theory
  val setup_cmd : (((((string * Position.T) * int (*precedence*)) * string (*pattern*))
        * (binding * string option * mixfix) list)
        * Input.source (* proc source*)) * string (*comment*) -> local_theory -> local_theory
end

structure NuProcessor : NU_PROCESSOR = struct
open Thm NuBasics
exception Bypass of (thm * Proof.context) option
type binding = Binding.binding
exception ProcessTerminated of (thm * Proof.context) * Token.T list
exception ProcessFail of binding * (thm * Proof.context) * exn
exception Process_State_Call of Token.T list * (thm * Proof.context) * (Proof.state -> Proof.state)
exception Process_State_Call' of (thm * Proof.context) * (Proof.state -> Proof.state)

val trace = Attrib.setup_config_bool \<^binding>\<open>\<nu>trace_processing\<close> (K false);

type proc = Proof.context -> thm -> (unit -> thm * Proof.context) parser

datatype processor = Processor of {
              binding : binding,
              precedence : int,
              pattern : term,
              enabled : bool,
              proc : proc
            }
fun precedence_of (Processor{precedence,...}) = precedence
fun proc_of (Processor{proc,...}) = proc
fun proc_ord (a,b) = int_ord (precedence_of a, precedence_of b)
fun mk_processor (binding, precedence, pat, proc) =
      Processor {binding = binding, precedence = precedence, pattern = pat, enabled = true, proc = proc}
fun set_enabled v (Processor {binding, precedence, pattern, enabled, proc}) =
      Processor {binding = binding, precedence = precedence, pattern = pattern, enabled = v, proc = proc}

structure Data = Generic_Data
(
  type T = processor Name_Space.table;
  val empty: T = Name_Space.empty_table "\<nu>processor";
  val extend = I;
  fun merge data : T = Name_Space.merge_tables data;
);

val ops_processor = {get_data = Data.get, put_data = Data.put}
fun define binding precedence pat proc =
      Entity.define ops_processor binding (mk_processor (binding, precedence, pat, proc)) #> #2
val list = Data.get #> Name_Space.dest_table
      #> map (fn (name, Processor {binding,pattern, ...}) => (Binding.name name,pattern))
val get = Data.get #> Name_Space.get
fun wrap_attr proc =
  Parse.args >> (fn toks =>
    Thm.rule_attribute [] (fn ctxt => fn th =>
      (proc (Context.proof_of ctxt) th --| Scan.catch Parse.eof) toks
              |> fst |> (fn f => f ()) |> fst))
val wrap_attr = wrap_attr : proc -> attribute parser
fun defined ctxt name =
  let
    val tab = Data.get ctxt
    val name = Name_Space.intern (Name_Space.space_of_table tab) name
  in
    Name_Space.defined tab name
  end
fun get_attr ctxt name =
  wrap_attr
    (proc_of (Name_Space.check ctxt (Data.get ctxt) name |> snd))

fun enable name =
      Data.map (Name_Space.map_table_entry name (set_enabled true))
fun disable name =
      Data.map (Name_Space.map_table_entry name (set_enabled false))

exception Processed of ((thm * Proof.context) * Token.T list)
fun eof_wrap parse [] = (fst (parse [Token.eof]), [])
  | eof_wrap parse toks = parse toks
fun process_impl procs (th_ctxt,toks) limit =
      let
        val prop = prop_of (fst th_ctxt)
        val th_ctxt = fold (fn (_, Processor {binding, pattern, enabled, proc,...}) => fn (th,ctxt) =>
          if not enabled then (th,ctxt)
          else if can (Pattern.match (Proof_Context.theory_of ctxt) (pattern, prop))
                        (Envir.type_env Envir.init, Envir.term_env Envir.init)
          then let
            val _ = if limit > 100 then error "too deep process" else ();
            val (execute,toks) =
              eof_wrap (proc ctxt th || (fn _ => raise Bypass NONE)) toks
            val _ = if Config.get ctxt trace
                    then tracing ("\<nu>process: " ^ Binding.print binding)
                    else ()
            in
            raise Processed (execute(), toks)
              handle Process_State_Call' (meta,f) =>
                  raise Process_State_Call (toks,meta,f)
            end handle Bypass NONE => (th,ctxt)
              | Bypass (SOME th_ctxt') => th_ctxt'
              | Processed th_ctx_toks => raise Processed th_ctx_toks
              | Process_State_Call arg => raise Process_State_Call arg
              | ProcessTerminated th_ctx_toks => raise ProcessTerminated th_ctx_toks
              | ex => (@{print} th; @{print} binding; Exn.reraise (@{print} ex))
            (* | ex => Exn.reraise (ProcessFail (binding,th,ex)) *)
          else (th,ctxt)) procs th_ctxt
      in (th_ctxt,toks)
      end
      handle Processed th_ctx_toks => process_impl procs th_ctx_toks (limit + 1)
        | ProcessTerminated th_toks => th_toks
        | NDBG th => ((th,snd th_ctxt),[Token.eof])

fun internal_process th ctxt toks =
  Runtime.exn_trace (fn _ =>
  process_impl
    (Data.get (Context.Proof ctxt) |> Name_Space.dest_table |> sort (proc_ord o apply2 snd))
    ((th,ctxt),toks) 0)

fun simple_process ctxt th toks =
  internal_process ctxt th toks handle Process_State_Call (toks,th_ctxt,f) => (th_ctxt,toks)

fun powerful_process toks stat =
  let
    val meta = the_nu_fact stat
  in
    stat
      |> Proof.map_context_result (fn ctxt =>
            (internal_process meta ctxt --| Scan.catch Parse.eof) toks
              |> #1
          )
      |-> NuBasics.set_nu_fact
    handle Process_State_Call (toks,(meta,ctxt),f) =>
      powerful_process toks (stat |> Proof.map_context (K ctxt)
                                  |> NuBasics.set_nu_fact meta
                                  |> f)
  end

val process_attr = wrap_attr (fn ctxt => fn th => simple_process th ctxt #> apfst K)
fun process_by_input tokens th ctxt = simple_process th ctxt (tokens @ [Token.eof]) |> #1
val process_no_input = process_by_input []



fun setup binding precedence term proc (comment:string) =
  define binding precedence term proc
fun setup' binding precedence (term,fixes) proc (comment:string) lthy =
  let
    val (_, lthy') = Proof_Context.add_fixes_cmd fixes lthy
    val term = Syntax.read_prop lthy' term |> free_to_var
  in
    define binding precedence term proc lthy
  end

fun setup_cmd (((((binding,precedence),term),fixes),proc),comment) ctxt =
  let
    val (_, ctxt') = Proof_Context.add_fixes_cmd fixes ctxt
    val term = Syntax.read_prop ctxt' term |> free_to_var
  in
    ctxt |> Context.proof_map (
      ML_Context.expression (Input.pos_of proc)
        (ML_Lex.read
          ("Theory.local_setup (NuProcessor.setup (" ^
          ML_Syntax.make_binding binding ^ ") (" ^ ML_Syntax.print_int precedence ^ ") ("
          ^ ML_Syntax.print_term term ^ ") (let open NuProcessor NuProcessors in ") @
          ML_Lex.read_source proc @
          ML_Lex.read (" end) " ^ ML_Syntax.print_string comment ^ ")"))
    )
  end

fun almost_safe f ctxt =
      if Config.get ctxt Nu_Reasoner.auto_level >= 1 then f ctxt else raise Bypass NONE
fun not_safe f ctxt =
      if Config.get ctxt Nu_Reasoner.auto_level >= 2 then f ctxt else raise Bypass NONE
fun parse_auto_level proc ctxt th =
  NuParse.auto_level #-> (fn auto_level' =>
    proc (Nu_Reasoner.reduce_auto_level auto_level' ctxt) th)

fun apply_attr ctxt th attr =
  attr (Context.Proof ctxt, th) |> #2 |> the

(* fun processor_parser (ctxt,tokens) =
val processor_attr = Scan.lift (Parse.named_position >> #1) --  *)
  
end
