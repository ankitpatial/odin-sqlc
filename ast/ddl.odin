package ast

// CREATE TABLE
Create_Table_Stmt :: struct {
	relation:       ^Range_Var,
	table_elts:     [dynamic]^Node, // Column_Def and Constraint nodes
	inh_relations:  [dynamic]^Node, // inherited tables
	partbound:      ^Node,
	partspec:       ^Node,
	of_typename:    ^Type_Name,
	constraints:    [dynamic]^Node,
	options:        [dynamic]^Node,
	oncommit:       i32,
	tablespacename: string,
	access_method:  string,
	if_not_exists:  bool,
}

// ALTER TABLE
Alter_Table_Stmt :: struct {
	relation:   ^Range_Var,
	cmds:       [dynamic]^Node, // Alter_Table_Cmd nodes
	objtype:    Object_Type,
	missing_ok: bool,
}

// ALTER TABLE subcommand
Alter_Table_Cmd :: struct {
	subtype:    Alter_Table_Type,
	name:       string,
	num:        i16,
	newowner:   ^Node, // RoleSpec
	def:        ^Node, // Column_Def, Constraint, etc.
	behavior:   Drop_Behavior,
	missing_ok: bool,
	recurse:    bool,
}

// DROP statement (table, type, function, schema, etc.)
Drop_Stmt :: struct {
	objects:     [dynamic]^Node,
	remove_type: Object_Type,
	behavior:    Drop_Behavior,
	missing_ok:  bool,
	concurrent:  bool,
}

// CREATE TYPE AS ENUM
Create_Enum_Stmt :: struct {
	type_name: [dynamic]^Node, // qualified name
	vals:      [dynamic]^Node, // String nodes
}

// ALTER TYPE (add value, rename value)
Alter_Enum_Stmt :: struct {
	type_name:              [dynamic]^Node,
	old_val:                string,
	new_val:                string,
	new_val_neighbor:       string,
	new_val_is_after:       bool,
	skip_if_new_val_exists: bool,
}

// CREATE FUNCTION / CREATE PROCEDURE
Create_Function_Stmt :: struct {
	is_procedure: bool,
	replace:      bool,
	funcname:     [dynamic]^Node,
	parameters:   [dynamic]^Node, // Function_Parameter nodes
	return_type:  ^Type_Name,
	options:      [dynamic]^Node,
	sql_body:     ^Node,
}

// Function parameter (in CREATE FUNCTION)
Function_Parameter :: struct {
	name:     string,
	arg_type: ^Type_Name,
	mode:     Func_Param_Mode,
	defexpr:  ^Node,
}

// DROP FUNCTION
Drop_Function_Stmt :: struct {
	objects:    [dynamic]^Node,
	behavior:   Drop_Behavior,
	missing_ok: bool,
}

// CREATE SCHEMA
Create_Schema_Stmt :: struct {
	schemaname:    string,
	authrole:      ^Node, // RoleSpec
	schema_elts:   [dynamic]^Node,
	if_not_exists: bool,
}

// DROP SCHEMA
Drop_Schema_Stmt :: struct {
	schemas:    [dynamic]string,
	behavior:   Drop_Behavior,
	missing_ok: bool,
}

// CREATE VIEW
Create_View_Stmt :: struct {
	view:                ^Range_Var,
	aliases:             [dynamic]^Node,
	query:               ^Node, // SELECT statement
	replace:             bool,
	options:             [dynamic]^Node,
	with_check_option:   i32,
}

// CREATE TABLE AS (SELECT ...)
Create_Table_As_Stmt :: struct {
	query:          ^Node,
	into:           ^Into_Clause,
	objtype:        Object_Type,
	is_select_into: bool,
	if_not_exists:  bool,
}

// RENAME (table, column, type, schema)
Rename_Stmt :: struct {
	rename_type:   Object_Type,
	relation_type: Object_Type,
	relation:      ^Range_Var,
	object:        ^Node,
	subname:       string, // old name
	newname:       string, // new name
	behavior:      Drop_Behavior,
	missing_ok:    bool,
}

// COMMENT ON
Comment_Stmt :: struct {
	objtype: Object_Type,
	object:  ^Node,
	comment: string,
}

// ALTER TYPE SET SCHEMA / ALTER TABLE SET SCHEMA
Alter_Object_Schema_Stmt :: struct {
	object_type: Object_Type,
	relation:    ^Range_Var,
	object:      ^Node,
	newschema:   string,
	missing_ok:  bool,
}

// CREATE EXTENSION
Create_Extension_Stmt :: struct {
	extname:       string,
	if_not_exists: bool,
	options:       [dynamic]^Node,
}

// CREATE COMPOSITE TYPE
Composite_Type_Stmt :: struct {
	typevar:    ^Range_Var,
	coldeflist: [dynamic]^Node,
}

// CREATE INDEX
Index_Stmt :: struct {
	idxname:                           string,
	relation:                          ^Range_Var,
	access_method:                     string,
	table_space:                       string,
	index_params:                      [dynamic]^Node,
	index_including_params:            [dynamic]^Node,
	options:                           [dynamic]^Node,
	where_clause:                      ^Node,
	exclude_op_names:                  [dynamic]^Node,
	idxcomment:                        string,
	index_oid:                         u32,
	old_number:                        u32,
	old_create_subid:                  u32,
	old_first_relfilelocator_subid:    u32,
	unique:                            bool,
	nulls_not_distinct:                bool,
	primary:                           bool,
	isconstraint:                      bool,
	deferrable:                        bool,
	initdeferred:                      bool,
	transformed:                       bool,
	concurrent:                        bool,
	if_not_exists:                     bool,
	reset_default_tblspc:              bool,
}

// CREATE SEQUENCE
Create_Seq_Stmt :: struct {
	sequence:      ^Range_Var,
	options:       [dynamic]^Node,
	owner_id:      u32,
	for_identity:  bool,
	if_not_exists: bool,
}

// ALTER SEQUENCE
Alter_Seq_Stmt :: struct {
	sequence:     ^Range_Var,
	options:      [dynamic]^Node,
	for_identity: bool,
	missing_ok:   bool,
}

// GRANT / REVOKE
Grant_Stmt :: struct {
	is_grant:     bool,
	targtype:     Grant_Target_Type,
	objtype:      Object_Type,
	objects:      [dynamic]^Node,
	privileges:   [dynamic]^Node,
	grantees:     [dynamic]^Node,
	grant_option: bool,
	grantor:      ^Node,
	behavior:     Drop_Behavior,
}

// DefElem (generic key=value for SET, options, etc.)
Def_Elem :: struct {
	defnamespace: string,
	defname:      string,
	arg:          ^Node,
	defaction:    Def_Elem_Action,
	location:     i32,
}

// Role specification (for owner, grantee)
Role_Spec :: struct {
	roletype: i32,
	rolename: string,
	location: i32,
}

// Transaction statement (BEGIN, COMMIT, ROLLBACK)
Transaction_Stmt :: struct {
	kind:            i32,
	options:         [dynamic]^Node,
	savepoint_name:  string,
	gid:             string,
	chain:           bool,
	location:        i32,
}

// DO statement (anonymous code block)
Do_Stmt :: struct {
	args: [dynamic]^Node,
}

// PREPARE statement
Prepare_Stmt :: struct {
	name:     string,
	argtypes: [dynamic]^Node,
	query:    ^Node,
}

// EXECUTE statement
Execute_Stmt :: struct {
	name:   string,
	params: [dynamic]^Node,
}
