package ast_tests

import "core:testing"
import ast "../"

@(test)
test_walk_select_stmt :: proc(t: ^testing.T) {
	// Build: SELECT id FROM users
	id_str := new(ast.Node)
	id_str^ = ast.String_Node{sval = "id"}

	cr_fields := make([dynamic]^ast.Node, 0, 1)
	append(&cr_fields, id_str)
	cr := new(ast.Node)
	cr^ = ast.Column_Ref{fields = cr_fields}

	rt := new(ast.Node)
	rt^ = ast.Res_Target{val = cr}

	rv_node := new(ast.Node)
	rv_node^ = ast.Range_Var{relname = "users"}

	tl := make([dynamic]^ast.Node, 0, 1)
	append(&tl, rt)
	fc := make([dynamic]^ast.Node, 0, 1)
	append(&fc, rv_node)

	sel := new(ast.Node)
	sel^ = ast.Select_Stmt{
		target_list = tl,
		from_clause = fc,
	}

	// Walk and count all nodes visited
	count := 0
	ast.walk(sel, proc(node: ^ast.Node, data: rawptr) -> bool {
		c := cast(^int)data
		c^ += 1
		return true
	}, &count)

	testing.expect(t, count >= 4, "expected at least 4 nodes visited")
}

@(test)
test_search_finds_column_ref :: proc(t: ^testing.T) {
	id_str := new(ast.Node)
	id_str^ = ast.String_Node{sval = "id"}

	cr_fields := make([dynamic]^ast.Node, 0, 1)
	append(&cr_fields, id_str)
	cr := new(ast.Node)
	cr^ = ast.Column_Ref{fields = cr_fields}

	rt := new(ast.Node)
	rt^ = ast.Res_Target{val = cr}

	tl := make([dynamic]^ast.Node, 0, 1)
	append(&tl, rt)
	sel := new(ast.Node)
	sel^ = ast.Select_Stmt{target_list = tl}

	found := ast.search(sel, proc(node: ^ast.Node) -> bool {
		_, ok := node^.(ast.Column_Ref)
		return ok
	})
	testing.expect(t, found != nil, "expected to find Column_Ref")
}

@(test)
test_search_returns_nil :: proc(t: ^testing.T) {
	sel := new(ast.Node)
	sel^ = ast.Select_Stmt{}

	found := ast.search(sel, proc(node: ^ast.Node) -> bool {
		_, ok := node^.(ast.Param_Ref)
		return ok
	})
	testing.expect(t, found == nil, "expected nil for no match")
}
