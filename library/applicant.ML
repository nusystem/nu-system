signature NU_APPLICANT = sig
  val applicant_thms : Proof.context -> (string * Position.T) -> thm list
  val declare_overloading : binding -> string (*comment*) -> local_theory -> string * local_theory
  val overload : thm -> (string * Position.T) -> Context.generic -> Context.generic
  val parser : (string * Position.T) parser
end

structure NuApplicant : NU_APPLICANT = struct

fun applicant_thms ctx (name,pos) =
  Proof_Context.get_fact ctx (Facts.Named ((suffix "_\<nu>app" name, pos), NONE))
  handle _ =>
  (Proof_Context.get_fact ctx (Facts.Named ((name, pos), NONE))
  handle _ =>
  Proof_Context.get_fact ctx (Facts.Named ((suffix "_\<nu>proc" name, pos), NONE)))

val declare_overloading = Named_Theorems.declare o Binding.suffix_name "_\<nu>app"
fun overload th (name,pos) ctx =
  Named_Theorems.add_thm (Named_Theorems.check (Context.proof_of ctx)
    (suffix "_\<nu>app" name, pos)) th ctx

local open Parse Scan in

val parser = position (short_ident || long_ident || sym_ident || keyword || string)

val _ =
  Outer_Syntax.local_theory @{command_keyword \<nu>overloads} "declare procedure overloads"
    (and_list1 (binding -- Scan.optional Parse.text "") >>
        (fold (fn (b,s) => declare_overloading b s #> #2)))

end

end
