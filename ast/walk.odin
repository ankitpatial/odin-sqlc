package ast

// Visitor callback — return false to stop walking.
Visitor :: #type proc(node: ^Node, user_data: rawptr) -> bool

// Walk the AST depth-first, calling visitor for each node.
// If visitor returns false, walking stops.
walk :: proc(node: ^Node, visitor: Visitor, user_data: rawptr) {
	if node == nil { return }
	if !visitor(node, user_data) { return }
	walk_children(node, visitor, user_data)
}

// Search for the first node matching a predicate.
search :: proc(node: ^Node, pred: proc(^Node) -> bool) -> ^Node {
	if node == nil { return nil }
	if pred(node) { return node }

	Search_State :: struct {
		pred:   proc(^Node) -> bool,
		result: ^Node,
	}
	state := Search_State{pred = pred}

	walk_children(node, proc(n: ^Node, data: rawptr) -> bool {
		s := cast(^Search_State)data
		if s.result != nil { return false }
		if s.pred(n) {
			s.result = n
			return false
		}
		return true
	}, &state)

	return state.result
}

// Apply a transformation to every node (depth-first, post-order).
apply :: proc(node: ^Node, transform: proc(^Node) -> ^Node) {
	if node == nil { return }
	apply_children(node, transform)
	new_node := transform(node)
	if new_node != nil && new_node != node {
		node^ = new_node^
	}
}

// ── Internal: walk into all child nodes ───────────────────────

walk_children :: proc(node: ^Node, visitor: Visitor, user_data: rawptr) {
	if node == nil { return }

	#partial switch &n in node^ {
	// DML Statements
	case Select_Stmt:
		walk_list(n.distinct_clause, visitor, user_data)
		walk(n.into_clause, visitor, user_data)
		walk_list(n.target_list, visitor, user_data)
		walk_list(n.from_clause, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.group_clause, visitor, user_data)
		walk(n.having_clause, visitor, user_data)
		walk_list(n.window_clause, visitor, user_data)
		walk_list(n.sort_clause, visitor, user_data)
		walk(n.limit_offset, visitor, user_data)
		walk(n.limit_count, visitor, user_data)
		walk_list(n.locking_clause, visitor, user_data)
		// Typed pointer children — wrap in temp Node to walk
		if n.with_clause != nil {
			walk_list(n.with_clause.ctes, visitor, user_data)
		}
		if n.larg != nil {
			temp: Node = n.larg^
			walk(&temp, visitor, user_data)
		}
		if n.rarg != nil {
			temp: Node = n.rarg^
			walk(&temp, visitor, user_data)
		}

	case Insert_Stmt:
		walk_list(n.cols, visitor, user_data)
		walk(n.select_stmt, visitor, user_data)
		walk_list(n.returning_list, visitor, user_data)
		if n.with_clause != nil {
			walk_list(n.with_clause.ctes, visitor, user_data)
		}

	case Update_Stmt:
		walk_list(n.target_list, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.from_clause, visitor, user_data)
		walk_list(n.returning_list, visitor, user_data)
		if n.with_clause != nil {
			walk_list(n.with_clause.ctes, visitor, user_data)
		}

	case Delete_Stmt:
		walk_list(n.using_clause, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.returning_list, visitor, user_data)
		if n.with_clause != nil {
			walk_list(n.with_clause.ctes, visitor, user_data)
		}

	case Truncate_Stmt:
		walk_list(n.relations, visitor, user_data)

	case Explain_Stmt:
		walk(n.query, visitor, user_data)
		walk_list(n.options, visitor, user_data)

	case Copy_Stmt:
		walk(n.query, visitor, user_data)
		walk_list(n.attlist, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.where_clause, visitor, user_data)

	// Expressions
	case A_Expr:
		walk_list(n.name, visitor, user_data)
		walk(n.lexpr, visitor, user_data)
		walk(n.rexpr, visitor, user_data)

	case Bool_Expr:
		walk_list(n.args, visitor, user_data)

	case Func_Call:
		walk_list(n.funcname, visitor, user_data)
		walk_list(n.args, visitor, user_data)
		walk_list(n.agg_order, visitor, user_data)
		walk(n.agg_filter, visitor, user_data)

	case Type_Cast:
		walk(n.arg, visitor, user_data)

	case Case_Expr:
		walk(n.arg, visitor, user_data)
		walk_list(n.args, visitor, user_data)
		walk(n.defresult, visitor, user_data)

	case Case_When:
		walk(n.expr, visitor, user_data)
		walk(n.result, visitor, user_data)

	case Sub_Link:
		walk(n.testexpr, visitor, user_data)
		walk_list(n.oper_name, visitor, user_data)
		walk(n.subselect, visitor, user_data)

	case Coalesce_Expr:
		walk_list(n.args, visitor, user_data)

	case Null_Test:
		walk(n.arg, visitor, user_data)

	case Boolean_Test:
		walk(n.arg, visitor, user_data)

	case Row_Expr:
		walk_list(n.args, visitor, user_data)
		walk_list(n.colnames, visitor, user_data)

	case A_Array_Expr:
		walk_list(n.elements, visitor, user_data)

	case A_Indices:
		walk(n.lidx, visitor, user_data)
		walk(n.uidx, visitor, user_data)

	case A_Indirection:
		walk(n.arg, visitor, user_data)
		walk_list(n.indirection, visitor, user_data)

	case Min_Max_Expr:
		walk_list(n.args, visitor, user_data)

	case Xml_Expr:
		walk_list(n.named_args, visitor, user_data)
		walk_list(n.arg_names, visitor, user_data)
		walk_list(n.args, visitor, user_data)

	case Paren_Expr:
		walk(n.arg, visitor, user_data)

	// References
	case Column_Ref:
		walk_list(n.fields, visitor, user_data)

	case Range_Subselect:
		walk(n.subquery, visitor, user_data)

	case Range_Function:
		walk_list(n.functions, visitor, user_data)
		walk_list(n.coldeflist, visitor, user_data)

	case Join_Expr:
		walk(n.larg, visitor, user_data)
		walk(n.rarg, visitor, user_data)
		walk_list(n.using_clause, visitor, user_data)
		walk(n.quals, visitor, user_data)

	// Types / Definitions
	case Res_Target:
		walk_list(n.indirection, visitor, user_data)
		walk(n.val, visitor, user_data)

	case Column_Def:
		walk(n.raw_default, visitor, user_data)
		walk(n.cooked_default, visitor, user_data)
		walk(n.coll_clause, visitor, user_data)
		walk_list(n.constraints, visitor, user_data)
		walk_list(n.fdwoptions, visitor, user_data)

	case Constraint:
		walk(n.raw_expr, visitor, user_data)
		walk_list(n.keys, visitor, user_data)
		walk_list(n.including, visitor, user_data)
		walk_list(n.exclusions, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.fk_attrs, visitor, user_data)
		walk_list(n.pk_attrs, visitor, user_data)
		walk_list(n.fk_del_set_cols, visitor, user_data)

	case Sort_By:
		walk(n.node, visitor, user_data)
		walk_list(n.use_op, visitor, user_data)

	case Window_Def:
		walk_list(n.partition_clause, visitor, user_data)
		walk_list(n.order_clause, visitor, user_data)
		walk(n.start_offset, visitor, user_data)
		walk(n.end_offset, visitor, user_data)

	case Locking_Clause:
		walk_list(n.locked_rels, visitor, user_data)

	case On_Conflict_Clause:
		walk(n.infer, visitor, user_data)
		walk_list(n.target_list, visitor, user_data)
		walk(n.where_clause, visitor, user_data)

	case Infer_Clause:
		walk_list(n.index_elems, visitor, user_data)
		walk(n.where_clause, visitor, user_data)

	case Index_Elem:
		walk(n.expr, visitor, user_data)
		walk_list(n.collation, visitor, user_data)
		walk_list(n.opclass, visitor, user_data)
		walk_list(n.opclassopts, visitor, user_data)

	case Multi_Assign_Ref:
		walk(n.source, visitor, user_data)

	case Grouping_Set:
		walk_list(n.content, visitor, user_data)

	case Into_Clause:
		walk_list(n.col_names, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.view_query, visitor, user_data)

	// Containers
	case List:
		walk_list(n.items, visitor, user_data)

	case Raw_Stmt:
		walk(n.stmt, visitor, user_data)

	case With_Clause:
		walk_list(n.ctes, visitor, user_data)

	case Common_Table_Expr:
		walk_list(n.aliascolnames, visitor, user_data)
		walk(n.ctequery, visitor, user_data)
		walk_list(n.ctecolnames, visitor, user_data)

	// DDL
	case Create_Table_Stmt:
		walk_list(n.table_elts, visitor, user_data)
		walk_list(n.inh_relations, visitor, user_data)
		walk(n.partbound, visitor, user_data)
		walk(n.partspec, visitor, user_data)
		walk_list(n.constraints, visitor, user_data)
		walk_list(n.options, visitor, user_data)

	case Alter_Table_Stmt:
		walk_list(n.cmds, visitor, user_data)

	case Alter_Table_Cmd:
		walk(n.newowner, visitor, user_data)
		walk(n.def, visitor, user_data)

	case Drop_Stmt:
		walk_list(n.objects, visitor, user_data)

	case Create_Enum_Stmt:
		walk_list(n.type_name, visitor, user_data)
		walk_list(n.vals, visitor, user_data)

	case Alter_Enum_Stmt:
		walk_list(n.type_name, visitor, user_data)

	case Create_Function_Stmt:
		walk_list(n.funcname, visitor, user_data)
		walk_list(n.parameters, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.sql_body, visitor, user_data)

	case Function_Parameter:
		walk(n.defexpr, visitor, user_data)

	case Drop_Function_Stmt:
		walk_list(n.objects, visitor, user_data)

	case Create_Schema_Stmt:
		walk(n.authrole, visitor, user_data)
		walk_list(n.schema_elts, visitor, user_data)

	case Create_View_Stmt:
		walk_list(n.aliases, visitor, user_data)
		walk(n.query, visitor, user_data)
		walk_list(n.options, visitor, user_data)

	case Create_Table_As_Stmt:
		walk(n.query, visitor, user_data)

	case Rename_Stmt:
		walk(n.object, visitor, user_data)

	case Comment_Stmt:
		walk(n.object, visitor, user_data)

	case Alter_Object_Schema_Stmt:
		walk(n.object, visitor, user_data)

	case Create_Extension_Stmt:
		walk_list(n.options, visitor, user_data)

	case Composite_Type_Stmt:
		walk_list(n.coldeflist, visitor, user_data)

	case Index_Stmt:
		walk_list(n.index_params, visitor, user_data)
		walk_list(n.index_including_params, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.exclude_op_names, visitor, user_data)

	case Create_Seq_Stmt:
		walk_list(n.options, visitor, user_data)

	case Alter_Seq_Stmt:
		walk_list(n.options, visitor, user_data)

	case Grant_Stmt:
		walk_list(n.objects, visitor, user_data)
		walk_list(n.privileges, visitor, user_data)
		walk_list(n.grantees, visitor, user_data)
		walk(n.grantor, visitor, user_data)

	case Def_Elem:
		walk(n.arg, visitor, user_data)

	case Transaction_Stmt:
		walk_list(n.options, visitor, user_data)

	case Do_Stmt:
		walk_list(n.args, visitor, user_data)

	case Prepare_Stmt:
		walk_list(n.argtypes, visitor, user_data)
		walk(n.query, visitor, user_data)

	case Execute_Stmt:
		walk_list(n.params, visitor, user_data)

	// Leaf nodes (no children): A_Const, String_Node, Integer_Node,
	// Float_Node, Boolean_Node, A_Star, Param_Ref, Sql_Value_Function,
	// Set_To_Default, Role_Spec, Drop_Schema_Stmt, Table_Name, Func_Name
	// — no case needed (handled by #partial switch default)
	}
}

// Walk a list of node pointers.
walk_list :: proc(nodes: [dynamic]^Node, visitor: Visitor, user_data: rawptr) {
	for node in nodes {
		walk(node, visitor, user_data)
	}
}

// Apply transform to all children (internal).
apply_children :: proc(node: ^Node, transform: proc(^Node) -> ^Node) {
	if node == nil { return }

	apply_to_list :: proc(nodes: [dynamic]^Node, transform: proc(^Node) -> ^Node) {
		for i := 0; i < len(nodes); i += 1 {
			if nodes[i] != nil {
				apply(nodes[i], transform)
			}
		}
	}

	apply_to_node :: proc(n: ^Node, transform: proc(^Node) -> ^Node) {
		if n != nil { apply(n, transform) }
	}

	// Mirror walk_children structure but call apply recursively
	#partial switch &n in node^ {
	case Select_Stmt:
		apply_to_list(n.target_list, transform)
		apply_to_list(n.from_clause, transform)
		apply_to_node(n.where_clause, transform)
		apply_to_list(n.group_clause, transform)
		apply_to_node(n.having_clause, transform)
		apply_to_list(n.sort_clause, transform)
		apply_to_node(n.limit_offset, transform)
		apply_to_node(n.limit_count, transform)

	case Insert_Stmt:
		apply_to_list(n.cols, transform)
		apply_to_node(n.select_stmt, transform)
		apply_to_list(n.returning_list, transform)

	case Update_Stmt:
		apply_to_list(n.target_list, transform)
		apply_to_node(n.where_clause, transform)
		apply_to_list(n.from_clause, transform)
		apply_to_list(n.returning_list, transform)

	case Delete_Stmt:
		apply_to_list(n.using_clause, transform)
		apply_to_node(n.where_clause, transform)
		apply_to_list(n.returning_list, transform)

	case A_Expr:
		apply_to_node(n.lexpr, transform)
		apply_to_node(n.rexpr, transform)

	case Bool_Expr:
		apply_to_list(n.args, transform)

	case Func_Call:
		apply_to_list(n.args, transform)
		apply_to_node(n.agg_filter, transform)

	case Case_Expr:
		apply_to_node(n.arg, transform)
		apply_to_list(n.args, transform)
		apply_to_node(n.defresult, transform)

	case Case_When:
		apply_to_node(n.expr, transform)
		apply_to_node(n.result, transform)

	case Sub_Link:
		apply_to_node(n.testexpr, transform)
		apply_to_node(n.subselect, transform)

	case Coalesce_Expr:
		apply_to_list(n.args, transform)

	case Null_Test:
		apply_to_node(n.arg, transform)

	case Column_Ref:
		apply_to_list(n.fields, transform)

	case Res_Target:
		apply_to_node(n.val, transform)

	case Join_Expr:
		apply_to_node(n.larg, transform)
		apply_to_node(n.rarg, transform)
		apply_to_node(n.quals, transform)

	case List:
		apply_to_list(n.items, transform)

	case Raw_Stmt:
		apply_to_node(n.stmt, transform)
	}
}
