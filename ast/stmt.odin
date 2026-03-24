package ast

// SELECT statement
Select_Stmt :: struct {
	distinct_clause: [dynamic]^Node,
	into_clause:     ^Node, // IntoClause
	target_list:     [dynamic]^Node,
	from_clause:     [dynamic]^Node,
	where_clause:    ^Node,
	group_clause:    [dynamic]^Node,
	group_distinct:  bool,
	having_clause:   ^Node,
	window_clause:   [dynamic]^Node,
	values_lists:    [dynamic][dynamic]^Node,
	sort_clause:     [dynamic]^Node,
	limit_offset:    ^Node,
	limit_count:     ^Node,
	limit_option:    Limit_Option,
	locking_clause:  [dynamic]^Node,
	with_clause:     ^With_Clause,
	op:              Set_Operation,
	all:             bool,
	larg:            ^Select_Stmt,
	rarg:            ^Select_Stmt,
}

// INSERT statement
Insert_Stmt :: struct {
	relation:       ^Range_Var,
	cols:           [dynamic]^Node,
	select_stmt:    ^Node, // SELECT or VALUES
	on_conflict:    ^On_Conflict_Clause,
	returning_list: [dynamic]^Node,
	with_clause:    ^With_Clause,
	override:       i32, // OverridingKind
}

// UPDATE statement
Update_Stmt :: struct {
	relation:       ^Range_Var,
	target_list:    [dynamic]^Node,
	where_clause:   ^Node,
	from_clause:    [dynamic]^Node,
	returning_list: [dynamic]^Node,
	with_clause:    ^With_Clause,
}

// DELETE statement
Delete_Stmt :: struct {
	relation:       ^Range_Var,
	using_clause:   [dynamic]^Node,
	where_clause:   ^Node,
	returning_list: [dynamic]^Node,
	with_clause:    ^With_Clause,
}

// TRUNCATE statement
Truncate_Stmt :: struct {
	relations:    [dynamic]^Node,
	restart_seqs: bool,
	behavior:     Drop_Behavior,
}

// EXPLAIN statement
Explain_Stmt :: struct {
	query:   ^Node,
	options: [dynamic]^Node,
}

// COPY statement
Copy_Stmt :: struct {
	relation:     ^Range_Var,
	query:        ^Node,
	attlist:      [dynamic]^Node,
	is_from:      bool,
	is_program:   bool,
	filename:     string,
	options:      [dynamic]^Node,
	where_clause: ^Node,
}

// Range subselect (subquery in FROM)
Range_Subselect :: struct {
	lateral:  bool,
	subquery: ^Node,
	alias:    ^Alias,
}

// Range function (function call in FROM)
Range_Function :: struct {
	lateral:     bool,
	ordinality:  bool,
	is_rowsfrom: bool,
	functions:   [dynamic]^Node,
	alias:       ^Alias,
	coldeflist:  [dynamic]^Node,
}

// JOIN expression
Join_Expr :: struct {
	jointype:         Join_Type,
	is_natural:       bool,
	larg:             ^Node,
	rarg:             ^Node,
	using_clause:     [dynamic]^Node,
	join_using_alias: ^Alias,
	quals:            ^Node,
	alias:            ^Alias,
}

// INTO clause (SELECT INTO)
Into_Clause :: struct {
	rel:            ^Range_Var,
	col_names:      [dynamic]^Node,
	access_method:  string,
	options:        [dynamic]^Node,
	on_commit:      i32,
	tablespacename: string,
	view_query:     ^Node,
	skip_data:      bool,
}
