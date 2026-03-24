package ast

// Qualified table name (catalog.schema.name)
Table_Name :: struct {
	catalog: string,
	schema:  string,
	name:    string,
}

// Qualified type name
Type_Name :: struct {
	catalog:      string,
	schema:       string,
	name:         string,
	array_bounds: [dynamic]^Node,
	set_of:       bool,
	pct_type:     bool, // %TYPE notation
	typmods:      [dynamic]^Node,
	location:     i32,
}

// Qualified function name
Func_Name :: struct {
	catalog: string,
	schema:  string,
	name:    string,
}

// A raw statement from the parser with location info
Raw_Stmt :: struct {
	stmt:     ^Node,
	location: i32, // byte offset in source
	length:   i32, // byte length (0 = to end)
}

// Wraps a raw statement for catalog processing
Statement :: struct {
	raw: Raw_Stmt,
}

// Column reference (table.column or just column)
Column_Ref :: struct {
	fields:   [dynamic]^Node, // String nodes or A_Star
	location: i32,
}

// Parameter reference ($1, $2, ...)
Param_Ref :: struct {
	number:   i32,
	location: i32,
}

// A_Star represents * in SELECT * or table.*
A_Star :: struct {
	location: i32,
}

// A_Const represents a constant value
A_Const :: struct {
	type:     A_Const_Type,
	ival:     i64,
	fval:     string,
	bval:     bool,
	sval:     string,
	bsval:    string, // bit string
	location: i32,
}

// String node (used in lists like column ref fields)
String_Node :: struct {
	sval: string,
}

// Integer node
Integer_Node :: struct {
	ival: i64,
}

// Float node (stored as string for precision)
Float_Node :: struct {
	fval: string,
}

// Boolean node
Boolean_Node :: struct {
	boolval: bool,
}

// Table alias
Alias :: struct {
	aliasname: string,
	colnames:  [dynamic]^Node,
}

// Range variable (table reference in FROM clause)
Range_Var :: struct {
	catalogname:    string,
	schemaname:     string,
	relname:        string,
	inh:            bool, // inheritance?
	relpersistence: byte, // 'p', 'u', 't'
	alias:          ^Alias,
	location:       i32,
}

// Result target (SELECT target list item or INSERT/UPDATE column)
Res_Target :: struct {
	name:        string, // column name (for INSERT/UPDATE) or alias (for SELECT)
	indirection: [dynamic]^Node,
	val:         ^Node, // expression
	location:    i32,
}

// Column definition (in CREATE TABLE)
Column_Def :: struct {
	colname:        string,
	type_name:      ^Type_Name,
	compression:    string,
	inhcount:       i32,
	is_local:       bool,
	is_not_null:    bool,
	is_from_type:   bool,
	storage:        byte,
	raw_default:    ^Node,
	cooked_default: ^Node,
	identity:       byte,
	generated:      byte,
	coll_clause:    ^Node,
	coll_oid:       u32,
	constraints:    [dynamic]^Node,
	fdwoptions:     [dynamic]^Node,
	location:       i32,
}

// Constraint definition
Constraint :: struct {
	contype:               Constraint_Type,
	conname:               string,
	deferrable:            bool,
	initdeferred:          bool,
	location:              i32,
	is_no_inherit:         bool,
	raw_expr:              ^Node,
	cooked_expr:           string,
	generated_when:        byte,
	keys:                  [dynamic]^Node,
	including:             [dynamic]^Node,
	exclusions:            [dynamic]^Node,
	options:               [dynamic]^Node,
	indexname:             string,
	indexspace:            string,
	reset_default_tblspc:  bool,
	access_method:         string,
	where_clause:          ^Node,
	pktable:               ^Range_Var,
	fk_attrs:              [dynamic]^Node,
	pk_attrs:              [dynamic]^Node,
	fk_matchtype:          byte,
	fk_upd_action:         byte,
	fk_del_action:         byte,
	fk_del_set_cols:       [dynamic]^Node,
	old_conpfeqop:         [dynamic]^Node,
	old_pktable_oid:       u32,
	skip_validation:       bool,
	initially_valid:       bool,
}

// WITH clause
With_Clause :: struct {
	ctes:      [dynamic]^Node,
	recursive: bool,
	location:  i32,
}

// Common Table Expression (CTE)
Common_Table_Expr :: struct {
	ctename:          string,
	aliascolnames:    [dynamic]^Node,
	ctematerialized:  i32,
	ctequery:         ^Node,
	location:         i32,
	cterecursive:     bool,
	cterefcount:      i32,
	ctecolnames:      [dynamic]^Node,
	ctecoltypes:      [dynamic]^Node,
	ctecoltypmods:    [dynamic]^Node,
	ctecolcollations: [dynamic]^Node,
}

// ON CONFLICT clause
On_Conflict_Clause :: struct {
	action:       On_Conflict_Action,
	infer:        ^Node, // InferClause
	target_list:  [dynamic]^Node,
	where_clause: ^Node,
	location:     i32,
}

// Sort-by clause (ORDER BY item)
Sort_By :: struct {
	node:         ^Node,
	sortby_dir:   Sort_By_Dir,
	sortby_nulls: Sort_By_Nulls,
	use_op:       [dynamic]^Node,
	location:     i32,
}

// Window definition
Window_Def :: struct {
	name:             string,
	refname:          string,
	partition_clause: [dynamic]^Node,
	order_clause:     [dynamic]^Node,
	frame_options:    i32,
	start_offset:     ^Node,
	end_offset:       ^Node,
	location:         i32,
}

// Locking clause (FOR UPDATE/SHARE)
Locking_Clause :: struct {
	locked_rels: [dynamic]^Node,
	strength:    Lock_Clause_Strength,
	wait_policy: i32,
}

// Generic List (used throughout the AST)
List :: struct {
	items: [dynamic]^Node,
}

// Infer clause (for ON CONFLICT)
Infer_Clause :: struct {
	index_elems:  [dynamic]^Node,
	where_clause: ^Node,
	conname:      string,
	location:     i32,
}

// Index element
Index_Elem :: struct {
	name:            string,
	expr:            ^Node,
	indexcolname:    string,
	collation:       [dynamic]^Node,
	opclass:         [dynamic]^Node,
	opclassopts:     [dynamic]^Node,
	ordering:        Sort_By_Dir,
	nulls_ordering:  Sort_By_Nulls,
}

// Multi-assign reference (for UPDATE SET (a,b) = (SELECT ...))
Multi_Assign_Ref :: struct {
	source:   ^Node,
	colno:    i32,
	ncolumns: i32,
}

// Grouping Set
Grouping_Set :: struct {
	kind:     Grouping_Set_Kind,
	content:  [dynamic]^Node,
	location: i32,
}
