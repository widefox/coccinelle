open Common open Commonop


(*****************************************************************************)
(* The functor argument  *) 
(*****************************************************************************)

module XMATCH = struct

  (* ------------------------------------------------------------------------*)
  (* Combinators history *) 
  (* ------------------------------------------------------------------------*)
  (*
   * version0: 
   *   type ('a, 'b) matcher = 'a -> 'b -> bool
   *
   * version1: same but with a global variable holding the current binding
   *  BUT bug
   *   - can have multiple possibilities
   *   - globals sux
   *   - sometimes have to undo, cos if start match, then it binds, 
   *     and if later it does not match, then must undo the first binds.
   *     ex: when match parameters, can  try to match, but then we found far 
   *     later that the last argument of a function does not match
   *      => have to uando the binding !!!
   *      (can handle that too with a global, by saving the 
   *      global, ... but sux)
   *   => better not use global
   * 
   * version2: 
   *    type ('a, 'b) matcher = binding -> 'a -> 'b -> binding list
   *
   * Empty list mean failure (let matchfailure = []).
   * To be able to have pretty code, have to use partial application 
   * powa, and so the type is in fact
   *
   * version3:
   *    type ('a, 'b) matcher =  'a -> 'b -> binding -> binding list
   *
   * Then by defining the correct combinators, can have quite pretty code (that 
   * looks like the clean code of version0).
   * 
   * opti: return a lazy list of possible matchs ?
   * 
   *)

  (* ------------------------------------------------------------------------*)
  (* Standard type and operators  *) 
  (* ------------------------------------------------------------------------*)

  type tin = Lib_engine.metavars_binding
  (* 'x is a ('a * 'b) but in fact dont care about 'b, we just tag the SP *)
  type 'x tout = ('x * Lib_engine.metavars_binding) list 

  type ('a, 'b) matcher = 'a -> 'b  -> tin -> ('a * 'b) tout

  (* was >&&> *)
  let (>>=) m1 m2 = fun binding ->
    let xs = m1 binding in
    let xxs = xs +> List.map (fun ((a,b), binding) -> m2 a b binding) in
    List.flatten xxs

  let (>|+|>) m1 m2 = fun binding -> 
      let xs = m1 binding in
      if null xs
      then m2 binding
      else xs
      
  let (>||>) m1 m2 = fun binding ->
    if true then 
      m1 binding ++ m2 binding 
    else 
      (m1 >|+|> m2) binding


  let return res = fun binding -> 
    [res, binding]

  let fail = fun binding -> 
    []

  (* ------------------------------------------------------------------------*)
  (* Exp  *) 
  (* ------------------------------------------------------------------------*)
  let cocciExp = fun expf expa node -> fun binding -> 

    let globals = ref [] in
    let bigf = { 
      (* julia's style *)
      Visitor_c.default_visitor_c with 
      Visitor_c.kexpr = (fun (k, bigf) expb ->
	match expf expa expb binding with
	| [] -> (* failed *) k expb
	| xs -> globals := xs @ !globals);
      (* pad's style.
       * push2 expr globals;  k expr
       *  ...
       *  !globals +> List.fold_left (fun acc e -> acc >||> match_e_e expr e) 
       * (return false)
       * 
       *)
    }
    in
    Visitor_c.vk_node bigf node;
    !globals +> List.map (fun ((a, _exp), binding) -> 
      (a, node), binding
    )


  (* ------------------------------------------------------------------------*)
  (* Tokens *) 
  (* ------------------------------------------------------------------------*)
  let tag_mck_pos mck posmck =
    match mck with 
    | Ast_cocci.PLUS -> Ast_cocci.PLUS
    | Ast_cocci.CONTEXT (pos, xs) -> 
        assert (pos = None);
        Ast_cocci.CONTEXT (posmck, xs)
    | Ast_cocci.MINUS (pos, xs) -> 
        assert (pos = None);
        Ast_cocci.MINUS (posmck, xs)
  

  let tag_mck_pos_mcode (x,info, mck) posmck stuff = fun binding -> 
    [((x, info, tag_mck_pos mck posmck),stuff), binding]
    

  let tokenf ia ib = fun binding -> 
    let pos = Ast_c.get_pos_of_info ib in
    let posmck = Some (pos, pos) in
    tag_mck_pos_mcode ia posmck ib binding

  let tokenf_mck mck ib = fun binding -> 
    let pos = Ast_c.get_pos_of_info ib in
    let posmck = Some (pos, pos) in
    [(tag_mck_pos mck posmck, ib), binding]
    
    

  (* ------------------------------------------------------------------------*)
  (* Distribute mcode *) 
  (* ------------------------------------------------------------------------*)
  let distrf (ii_of_x_f) =
    fun mcode x -> fun binding -> 
    let (max, min) = Lib_parsing_c.max_min_by_pos (ii_of_x_f x)
    in
    let posmck = Some (min, max) (* subtil: and not max, min !!*) in
    tag_mck_pos_mcode mcode posmck x binding

  let distrf_e    = distrf (Lib_parsing_c.ii_of_expr)
  let distrf_args = distrf (Lib_parsing_c.ii_of_args)
  let distrf_type = distrf (Lib_parsing_c.ii_of_type)
  let distrf_param = distrf (Lib_parsing_c.ii_of_param)
  let distrf_params = distrf (Lib_parsing_c.ii_of_params)

  (* ------------------------------------------------------------------------*)
  (* Environment *) 
  (* ------------------------------------------------------------------------*)
  (* pre: if have declared a new metavar that hide another one, then
   * must be passed with a binding that deleted this metavar *)
  let check_add_metavars_binding keepTODO inherited = fun (k, valu) binding ->
    (match Common.optionise (fun () -> binding +> List.assoc k) with
    | Some (valu') ->
        if
          (match valu, valu' with
          | Ast_c.MetaIdVal a, Ast_c.MetaIdVal b -> a =$= b
          | Ast_c.MetaFuncVal a, Ast_c.MetaFuncVal b -> a =$= b
          | Ast_c.MetaLocalFuncVal a, Ast_c.MetaLocalFuncVal b -> 
              (* do something more ? *)
              a =$= b

          (* al_expr before comparing !!! and accept when they match.
           * Note that here we have Astc._expression, so it is a match
           * modulo isomorphism (there is no metavariable involved here,
           * just isomorphisms). => TODO call isomorphism_c_c instead of
           * =*=. Maybe would be easier to transform ast_c in ast_cocci
           * and call the iso engine of julia. *)
          | Ast_c.MetaExprVal a, Ast_c.MetaExprVal b -> 
              Lib_parsing_c.al_expr a =*= Lib_parsing_c.al_expr b
          | Ast_c.MetaStmtVal a, Ast_c.MetaStmtVal b -> 
              Lib_parsing_c.al_statement a =*= Lib_parsing_c.al_statement b
          | Ast_c.MetaTypeVal a, Ast_c.MetaTypeVal b -> 
              Lib_parsing_c.al_type a =*= Lib_parsing_c.al_type b

          | Ast_c.MetaExprListVal a, Ast_c.MetaExprListVal b -> 
              failwith "not handling MetaExprListVal"
          | Ast_c.MetaParamVal a, Ast_c.MetaParamVal b -> 
              failwith "not handling MetaParamVal"
          | Ast_c.MetaParamListVal a, Ast_c.MetaParamListVal b -> 
              failwith "not handling MetaParamListVal"
          | Ast_c.MetaTextVal a, Ast_c.MetaTextVal b -> a =$= b
          | _ -> raise Impossible
          ) 
        then [binding]
        else []

    | None -> 
        if inherited then []
        else 
          let valu' = 
            (match valu with
            | Ast_c.MetaIdVal a        -> Ast_c.MetaIdVal a
            | Ast_c.MetaFuncVal a      -> Ast_c.MetaFuncVal a
            | Ast_c.MetaLocalFuncVal a -> Ast_c.MetaLocalFuncVal a (* more ? *)
            | Ast_c.MetaExprVal a -> Ast_c.MetaExprVal (Lib_parsing_c.al_expr a)
            | Ast_c.MetaStmtVal a -> Ast_c.MetaStmtVal (Lib_parsing_c.al_statement a)
            | Ast_c.MetaTypeVal a -> Ast_c.MetaTypeVal (Lib_parsing_c.al_type a)
            | Ast_c.MetaExprListVal a ->  failwith "not handling MetaExprListVal"
            | Ast_c.MetaParamVal a ->     failwith "not handling MetaParamVal"
            | Ast_c.MetaParamListVal a -> failwith "not handling MetaParamListVal"
            | Ast_c.MetaTextVal s -> Ast_c.MetaTextVal s
            ) 
          in
          [binding +> Common.insert_assoc (k, valu')]
    )


  let envf keep inherited = fun (k, valu) binding -> 
    check_add_metavars_binding keep inherited (k, valu) binding
      +> List.map (fun binding -> (k,valu), binding)


end

(*****************************************************************************)
(* Entry point  *) 
(*****************************************************************************)
module MATCH  = Cocci_vs_c_3.COCCI_VS_C (XMATCH)


let match_re_node2 a b binding = 
  MATCH.rule_elem_node a b binding 
  (* take only the tagged-SP, the 'a' *)
  +> List.map (fun ((a,_b), binding) -> a, binding)
    

(* subtil: 3 args, otherwise profile nothing *)
let match_re_node a b c = 
  Common.profile_code "Pattern2.match_re_node" (fun () -> match_re_node2 a b c)


