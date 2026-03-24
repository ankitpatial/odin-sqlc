package ast_tests

import "core:testing"
import ast "../"

@(test)
test_node_select_stmt :: proc(t: ^testing.T) {
	sel := ast.Select_Stmt{
		op = .None,
	}
	node: ast.Node = sel
	_, ok := node.(ast.Select_Stmt)
	testing.expect(t, ok, "expected Select_Stmt variant")
}

@(test)
test_node_table_name :: proc(t: ^testing.T) {
	tn := ast.Table_Name{
		schema = "public",
		name   = "users",
	}
	testing.expect_value(t, tn.schema, "public")
	testing.expect_value(t, tn.name, "users")
}

@(test)
test_node_type_name :: proc(t: ^testing.T) {
	tn := ast.Type_Name{
		schema = "pg_catalog",
		name   = "int4",
	}
	testing.expect_value(t, tn.schema, "pg_catalog")
	testing.expect_value(t, tn.name, "int4")
}

@(test)
test_node_a_const_integer :: proc(t: ^testing.T) {
	c := ast.A_Const{
		type = .Integer,
		ival = 42,
	}
	node: ast.Node = c
	val, ok := node.(ast.A_Const)
	testing.expect(t, ok, "expected A_Const variant")
	testing.expect_value(t, val.type, ast.A_Const_Type.Integer)
	testing.expect_value(t, val.ival, i64(42))
}

@(test)
test_node_a_const_string :: proc(t: ^testing.T) {
	c := ast.A_Const{
		type = .String,
		sval = "hello",
	}
	node: ast.Node = c
	val, ok := node.(ast.A_Const)
	testing.expect(t, ok, "expected A_Const variant")
	testing.expect_value(t, val.sval, "hello")
}

@(test)
test_node_switch :: proc(t: ^testing.T) {
	insert := ast.Insert_Stmt{}
	node: ast.Node = insert

	found := false
	#partial switch _ in node {
	case ast.Select_Stmt:
		testing.expect(t, false, "should not be Select_Stmt")
	case ast.Insert_Stmt:
		found = true
	}
	testing.expect(t, found, "expected Insert_Stmt branch to execute")
}

@(test)
test_constraint_types :: proc(t: ^testing.T) {
	c := ast.Constraint{
		contype = .Primary_Key,
		conname = "pk_users",
	}
	testing.expect_value(t, c.contype, ast.Constraint_Type.Primary_Key)
	testing.expect_value(t, c.conname, "pk_users")
}

@(test)
test_func_call :: proc(t: ^testing.T) {
	fc := ast.Func_Call{
		agg_star     = true,
		agg_distinct = false,
		location     = 0,
	}
	node: ast.Node = fc
	val, ok := node.(ast.Func_Call)
	testing.expect(t, ok, "expected Func_Call variant")
	testing.expect(t, val.agg_star, "expected agg_star true")
}
