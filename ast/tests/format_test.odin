package ast_tests

import "core:testing"
import ast "../"

@(test)
test_format_column_ref :: proc(t: ^testing.T) {
	s := new(ast.Node)
	s^ = ast.String_Node{sval = "id"}
	fields := make([dynamic]^ast.Node, 0, 1)
	append(&fields, s)
	cr := new(ast.Node)
	cr^ = ast.Column_Ref{fields = fields}
	result := ast.format_node(cr)
	testing.expect_value(t, result, "id")
}

@(test)
test_format_qualified_column :: proc(t: ^testing.T) {
	s1 := new(ast.Node)
	s1^ = ast.String_Node{sval = "users"}
	s2 := new(ast.Node)
	s2^ = ast.String_Node{sval = "id"}
	fields := make([dynamic]^ast.Node, 0, 2)
	append(&fields, s1)
	append(&fields, s2)
	cr := new(ast.Node)
	cr^ = ast.Column_Ref{fields = fields}
	result := ast.format_node(cr)
	testing.expect_value(t, result, "users.id")
}

@(test)
test_format_star :: proc(t: ^testing.T) {
	star := new(ast.Node)
	star^ = ast.A_Star{}
	fields := make([dynamic]^ast.Node, 0, 1)
	append(&fields, star)
	cr := new(ast.Node)
	cr^ = ast.Column_Ref{fields = fields}
	result := ast.format_node(cr)
	testing.expect_value(t, result, "*")
}

@(test)
test_format_param_ref :: proc(t: ^testing.T) {
	pr := new(ast.Node)
	pr^ = ast.Param_Ref{number = 3}
	result := ast.format_node(pr)
	testing.expect_value(t, result, "$3")
}

@(test)
test_format_a_const_integer :: proc(t: ^testing.T) {
	c := new(ast.Node)
	c^ = ast.A_Const{type = .Integer, ival = 42}
	result := ast.format_node(c)
	testing.expect_value(t, result, "42")
}

@(test)
test_format_a_const_string :: proc(t: ^testing.T) {
	c := new(ast.Node)
	c^ = ast.A_Const{type = .String, sval = "hello"}
	result := ast.format_node(c)
	testing.expect_value(t, result, "'hello'")
}

@(test)
test_format_a_const_null :: proc(t: ^testing.T) {
	c := new(ast.Node)
	c^ = ast.A_Const{type = .Null}
	result := ast.format_node(c)
	testing.expect_value(t, result, "NULL")
}

@(test)
test_format_type_cast :: proc(t: ^testing.T) {
	arg := new(ast.Node)
	arg^ = ast.Param_Ref{number = 1}
	tn := new(ast.Type_Name)
	tn^ = ast.Type_Name{name = "text"}
	tc := new(ast.Node)
	tc^ = ast.Type_Cast{arg = arg, type_name = tn}
	result := ast.format_node(tc)
	testing.expect_value(t, result, "$1::text")
}
