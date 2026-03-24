package ast

// General expression (a op b, a LIKE b, etc.)
A_Expr :: struct {
	kind:     A_Expr_Kind,
	name:     [dynamic]^Node, // operator name
	lexpr:    ^Node,          // left operand
	rexpr:    ^Node,          // right operand
	location: i32,
}

// Boolean expression (AND, OR, NOT)
Bool_Expr :: struct {
	boolop:   Bool_Expr_Type,
	args:     [dynamic]^Node,
	location: i32,
}

// Function call
Func_Call :: struct {
	funcname:         [dynamic]^Node, // qualified function name
	args:             [dynamic]^Node,
	agg_order:        [dynamic]^Node,
	agg_filter:       ^Node,
	over:             ^Window_Def,
	agg_within_group: bool,
	agg_star:         bool,
	agg_distinct:     bool,
	func_variadic:    bool,
	funcformat:       i32, // CoercionForm
	location:         i32,
}

// Type cast (CAST or :: notation)
Type_Cast :: struct {
	arg:       ^Node,
	type_name: ^Type_Name,
	location:  i32,
}

// CASE expression
Case_Expr :: struct {
	casetype:   u32,
	casecollid: u32,
	arg:        ^Node,
	args:       [dynamic]^Node, // WHEN clauses
	defresult:  ^Node,          // ELSE clause
	location:   i32,
}

// WHEN clause (in CASE)
Case_When :: struct {
	expr:     ^Node, // condition
	result:   ^Node, // result value
	location: i32,
}

// Subquery link (EXISTS, IN, ANY, ALL, scalar subquery)
Sub_Link :: struct {
	sub_link_type: Sub_Link_Type,
	testexpr:      ^Node,
	oper_name:     [dynamic]^Node,
	subselect:     ^Node, // Select_Stmt
	location:      i32,
}

// COALESCE expression
Coalesce_Expr :: struct {
	coalescetype:   u32,
	coalescecollid: u32,
	args:           [dynamic]^Node,
	location:       i32,
}

// NULL test (IS NULL / IS NOT NULL)
Null_Test :: struct {
	arg:          ^Node,
	nulltesttype: Null_Test_Type,
	argisrow:     bool,
	location:     i32,
}

// Boolean test (IS TRUE / IS NOT TRUE / IS FALSE / IS NOT FALSE / IS UNKNOWN / IS NOT UNKNOWN)
Boolean_Test :: struct {
	arg:          ^Node,
	booltesttype: i32,
	location:     i32,
}

// Row expression (ROW(a, b, c))
Row_Expr :: struct {
	args:       [dynamic]^Node,
	row_typeid: u32,
	row_format: i32,
	colnames:   [dynamic]^Node,
	location:   i32,
}

// Array expression (ARRAY[a, b, c])
A_Array_Expr :: struct {
	elements: [dynamic]^Node,
	location: i32,
}

// Array index (a[1])
A_Indices :: struct {
	is_slice: bool,
	lidx:     ^Node,
	uidx:     ^Node,
}

// Indirection (a.b, a[1], etc.)
A_Indirection :: struct {
	arg:         ^Node,
	indirection: [dynamic]^Node,
}

// MinMax expression (GREATEST/LEAST)
Min_Max_Expr :: struct {
	minmaxtype:   u32,
	minmaxcollid: u32,
	inputcollid:  u32,
	op:           i32, // MinMaxOp
	args:         [dynamic]^Node,
	location:     i32,
}

// SQL/XML expression
Xml_Expr :: struct {
	op:         i32,
	name:       string,
	named_args: [dynamic]^Node,
	arg_names:  [dynamic]^Node,
	args:       [dynamic]^Node,
	xmloption:  i32,
	indent:     bool,
	type_id:    u32,
	typmod:     i32,
	location:   i32,
}

// SQLValueFunction (CURRENT_DATE, CURRENT_TIME, etc.)
Sql_Value_Function :: struct {
	op:       i32,
	type_id:  u32,
	typmod:   i32,
	location: i32,
}

// SetToDefault (DEFAULT keyword in INSERT/UPDATE)
Set_To_Default :: struct {
	type_id:   u32,
	typmod:    i32,
	collation: u32,
	location:  i32,
}

// Parenthesized expression
Paren_Expr :: struct {
	arg:      ^Node,
	location: i32,
}
