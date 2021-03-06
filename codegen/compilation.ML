signature NU_COMPILATION = sig
  val compile : theory -> string (* compile all interfaces in the theory to printer source *)
end

structure NuCompilation : NU_COMPILATION = struct


type config = {name_space: string}
fun w s buffer = s :: buffer  ;  fun wi i = w (string_of_int i)
fun tr_name #"\\" = "slash'_" | tr_name #"<" = "" | tr_name #">" = "" | tr_name c = str c
val w' = w o String.translate tr_name
fun wstr ss buffer = "\"" :: (ss @ ("\"" :: buffer))
fun w_ty name = w' (String.substring (name, 1, String.size name - 1))
fun uniq_id (c:config) b = wstr [string_of_int (length b), ".", (#name_space c)] b

(*TODO: when "TheoryName.name" is translated to `val name = ...`,
* how about "TheoryName.long1.long2.name"?
* It is an invalid name for `val long1.long2.name = ...`*)
fun w_const (c:config) name =
  case String.fields (fn c => c = #".") name of (h::l) =>
    if h = #name_space c then w' (String.concatWith "_'_" l) #> w "_gen"
    else w "NuCG_" #> w' name #> w "_gen"

fun compile_typ (Type (name, tys))
      = w "TyCG_" #> w' name #> fold (fn ty => w " (" #> compile_typ ty #> w ")") tys
  | compile_typ (TFree (name, _))   = w_ty name #> w "_t"
  | compile_typ (TVar ((name,i),_)) = w_ty name #> w "_t" #> wi i

(*bi: bound index, to translate `Bound` term  ;  c: config *)
fun compile_body bi c (Const ("Pure.type", Type ("itself", [ty]))) = compile_typ ty
  | compile_body bi c (Const (@{const_name LABEL_TAG}, _) $ (Abs (s,_,_))) = wstr [s]
  | compile_body bi c (Const (@{const_name UNIQ_ID}, _)) = uniq_id c
  | compile_body bi c (Const (name,_)) = w_const c name
  | compile_body bi c (Free (name,_)) = w' name #> w "_v"
  | compile_body bi c (Var ((name,i),_)) = w' name #> w "_v" #> wi i
  | compile_body bi c (Bound i) = w "b" #> wi (bi - i)
  | compile_body bi c (Abs (_,Type ("itself", [ty]),body))
      = w "(fn " #> compile_typ ty #> w " => " #> compile_body (bi+1) c body #> w ")"
  | compile_body bi c (Abs (_,_,body))
      = w "(fn b" #> wi (bi+1) #> w " => " #> compile_body (bi+1) c body #> w ")"
  | compile_body bi c (A $ B) = compile_body bi c A #> w " (" #> compile_body bi c B #> w ")"


fun compile_proc' c (Const ("Pure.eq",_) $ Const (name, _) $ B)
      = w "val " #> w_const c name #> w " = " #> compile_body 0 c B #> w "\n"

fun compile_proc c = compile_proc' c o Thm.prop_of


fun compile_interf c (i:NuProcedure.interface) = w "\n#> " #> compile_body 0 c (Thm.prop_of(#thm i))

fun compile thy =
  let val c = {name_space = Context.theory_name thy}
      val gen = w "structure NuCG_" #> w (Context.theory_name thy) #> w " = struct\n"
        #> fold (compile_proc c o NuProcedure.compilation_thm_of thy)
              (NuProcedure.procedures_of (Context.Theory thy) |> rev)
        #> w "val gen = I"
        #> fold (compile_interf c o #2) (NuProcedure.interfaces_of thy |> Symtab.dest)
        #> w "\nend"
  in String.concat (rev (gen [])) end

end
