package ast_tests

import "core:testing"
import "core:encoding/json"
import ast "../"
import pg_query "../../pg_query"

@(test)
test_convert_simple_select :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("SELECT 1")
	testing.expect(t, err == nil, "parse failed")
	testing.expect_value(t, len(stmts), 1)

	node := ast.convert_node(stmts[0].stmt_json)
	testing.expect(t, node != nil, "convert returned nil")

	sel, ok := node^.(ast.Select_Stmt)
	testing.expect(t, ok, "expected Select_Stmt")
	testing.expect_value(t, len(sel.target_list), 1)
}

@(test)
test_convert_select_from_where :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("SELECT id, name FROM users WHERE id = 1")
	testing.expect(t, err == nil, "parse failed")

	node := ast.convert_node(stmts[0].stmt_json)
	testing.expect(t, node != nil, "convert returned nil")

	sel, ok := node^.(ast.Select_Stmt)
	testing.expect(t, ok, "expected Select_Stmt")
	testing.expect_value(t, len(sel.target_list), 2)
	testing.expect_value(t, len(sel.from_clause), 1)
	testing.expect(t, sel.where_clause != nil, "expected WHERE clause")
}

@(test)
test_convert_insert :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("INSERT INTO users (name) VALUES ($1) RETURNING id")
	testing.expect(t, err == nil, "parse failed")

	node := ast.convert_node(stmts[0].stmt_json)
	testing.expect(t, node != nil, "convert returned nil")

	ins, ok := node^.(ast.Insert_Stmt)
	testing.expect(t, ok, "expected Insert_Stmt")
	testing.expect(t, ins.relation != nil, "expected relation")
	testing.expect_value(t, ins.relation.relname, "users")
	testing.expect_value(t, len(ins.cols), 1)
	testing.expect_value(t, len(ins.returning_list), 1)
}

@(test)
test_convert_create_table :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("CREATE TABLE users (id serial PRIMARY KEY, name text NOT NULL)")
	testing.expect(t, err == nil, "parse failed")

	node := ast.convert_node(stmts[0].stmt_json)
	testing.expect(t, node != nil, "convert returned nil")

	ct, ok := node^.(ast.Create_Table_Stmt)
	testing.expect(t, ok, "expected Create_Table_Stmt")
	testing.expect(t, ct.relation != nil, "expected relation")
	testing.expect_value(t, ct.relation.relname, "users")
	testing.expect_value(t, len(ct.table_elts), 2)
}

@(test)
test_convert_a_const_integer :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("SELECT 42")
	testing.expect(t, err == nil, "parse failed")

	node := ast.convert_node(stmts[0].stmt_json)
	sel, _ := node^.(ast.Select_Stmt)
	testing.expect_value(t, len(sel.target_list), 1)

	rt_node := sel.target_list[0]
	rt, rtok := rt_node^.(ast.Res_Target)
	testing.expect(t, rtok, "expected Res_Target")

	val_node := rt.val
	testing.expect(t, val_node != nil, "expected val")
	ac, acok := val_node^.(ast.A_Const)
	testing.expect(t, acok, "expected A_Const")
	testing.expect_value(t, ac.type, ast.A_Const_Type.Integer)
	testing.expect_value(t, ac.ival, i64(42))
}

@(test)
test_convert_column_ref :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("SELECT id FROM users")
	testing.expect(t, err == nil, "parse failed")

	node := ast.convert_node(stmts[0].stmt_json)
	sel, _ := node^.(ast.Select_Stmt)

	rt_node := sel.target_list[0]
	rt, _ := rt_node^.(ast.Res_Target)
	cr, crok := rt.val^.(ast.Column_Ref)
	testing.expect(t, crok, "expected Column_Ref")
	testing.expect_value(t, len(cr.fields), 1)
}

@(test)
test_convert_param_ref :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("SELECT $1")
	testing.expect(t, err == nil, "parse failed")

	node := ast.convert_node(stmts[0].stmt_json)
	sel, _ := node^.(ast.Select_Stmt)
	rt, _ := sel.target_list[0]^.(ast.Res_Target)
	pr, prok := rt.val^.(ast.Param_Ref)
	testing.expect(t, prok, "expected Param_Ref")
	testing.expect_value(t, pr.number, i32(1))
}

@(test)
test_translate_create_table_not_null :: proc(t: ^testing.T) {
	sql := "CREATE TABLE users (id serial PRIMARY KEY, name text NOT NULL, email text)"
	stmts, err := pg_query.parse(sql)
	testing.expect(t, err == nil, "parse failed")

	node := ast.translate(stmts[0].stmt_json)
	testing.expect(t, node != nil, "translate returned nil")

	ct, ok := node^.(ast.Create_Table_Stmt)
	testing.expect(t, ok, "expected Create_Table_Stmt")
	testing.expect_value(t, len(ct.table_elts), 3)

	cd0, cd0ok := ct.table_elts[0]^.(ast.Column_Def)
	testing.expect(t, cd0ok, "expected Column_Def")
	testing.expect_value(t, cd0.colname, "id")
	testing.expect(t, cd0.is_not_null, "id should be NOT NULL (primary key)")

	cd1, cd1ok := ct.table_elts[1]^.(ast.Column_Def)
	testing.expect(t, cd1ok, "expected Column_Def")
	testing.expect_value(t, cd1.colname, "name")
	testing.expect(t, cd1.is_not_null, "name should be NOT NULL")

	cd2, cd2ok := ct.table_elts[2]^.(ast.Column_Def)
	testing.expect(t, cd2ok, "expected Column_Def")
	testing.expect_value(t, cd2.colname, "email")
	testing.expect(t, !cd2.is_not_null, "email should be nullable")
}

@(test)
test_translate_select_passthrough :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("SELECT 1")
	testing.expect(t, err == nil, "parse failed")

	node := ast.translate(stmts[0].stmt_json)
	_, ok := node^.(ast.Select_Stmt)
	testing.expect(t, ok, "SELECT should pass through translate to convert_node")
}
