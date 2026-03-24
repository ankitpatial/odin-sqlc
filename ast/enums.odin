package ast

// Set operations for UNION/INTERSECT/EXCEPT
Set_Operation :: enum {
	None,
	Union,
	Intersect,
	Except,
}

// Boolean expression types
Bool_Expr_Type :: enum {
	And,
	Or,
	Not,
}

// Expression kinds for A_Expr
A_Expr_Kind :: enum {
	Normal,      // normal operator
	Op,          // operator (same as Normal in most contexts)
	Like,        // LIKE
	ILike,       // ILIKE
	Similar,     // SIMILAR TO
	Between,     // BETWEEN
	Not_Between, // NOT BETWEEN
	In,          // IN
	Not_In,      // NOT IN
}

// Subquery link types
Sub_Link_Type :: enum {
	Exists,
	All,
	Any,
	Row_Compare,
	Expr,
	Multiexpr,
	Array,
}

// Function parameter modes
Func_Param_Mode :: enum {
	In,
	Out,
	In_Out,
	Variadic,
	Table,
	Default,
}

// DROP behavior
Drop_Behavior :: enum {
	Restrict,
	Cascade,
}

// Object types for DROP/ALTER
Object_Type :: enum {
	Table,
	Sequence,
	View,
	Materialized_View,
	Index,
	Foreign_Table,
	Type,
	Schema,
	Function,
	Procedure,
	Aggregate,
	Operator,
	Extension,
	Policy,
	Rule,
	Trigger,
	Event_Trigger,
	Collation,
	Conversion,
	Domain,
	Access_Method,
	Cast,
}

// NULL test types
Null_Test_Type :: enum {
	Is_Null,
	Is_Not_Null,
}

// Sort order
Sort_By_Dir :: enum {
	Default,
	Asc,
	Desc,
	Using,
}

// NULL ordering
Sort_By_Nulls :: enum {
	Default,
	First,
	Last,
}

// JOIN types
Join_Type :: enum {
	Inner,
	Left,
	Full,
	Right,
	Semi,
	Anti,
	Unique_Inner,
	Unique_Outer,
}

// Constraint types
Constraint_Type :: enum {
	Null,
	Not_Null,
	Default,
	Identity,
	Generated,
	Check,
	Primary_Key,
	Unique,
	Exclusion,
	Foreign_Key,
	Attr_Deferrable,
	Attr_Not_Deferrable,
	Attr_Deferred,
	Attr_Immediate,
}

// ALTER TABLE subcommand types
Alter_Table_Type :: enum {
	Add_Column,
	Drop_Column,
	Alter_Column_Type,
	Alter_Column_Set_Default,
	Alter_Column_Drop_Default,
	Alter_Column_Set_Not_Null,
	Alter_Column_Drop_Not_Null,
	Add_Constraint,
	Drop_Constraint,
	Set_Schema,
	Set_Owner,
	Rename_Column,
	Rename_Table,
	Add_Index,
}

// On conflict action
On_Conflict_Action :: enum {
	None,
	Nothing,
	Update,
}

// Constant value types
A_Const_Type :: enum {
	Integer,
	Float,
	Boolean,
	String,
	Bit_String,
	Null,
}

// Foreign key actions
FK_Action :: enum {
	No_Action,
	Restrict,
	Cascade,
	Set_Null,
	Set_Default,
}

// DefElem action (for SET, ADD, DROP)
Def_Elem_Action :: enum {
	Unspec,
	Set,
	Add,
	Drop,
}

// Keyword for GRANT/REVOKE
Grant_Target_Type :: enum {
	Object,
	All_In_Schema,
	Defaults,
}

// Lock clause strength (FOR UPDATE/SHARE)
Lock_Clause_Strength :: enum {
	None,
	For_Key_Share,
	For_Share,
	For_No_Key_Update,
	For_Update,
}

// Limit option
Limit_Option :: enum {
	Default,
	Count,
	Percent,
	With_Ties,
}

// Grouping set kind
Grouping_Set_Kind :: enum {
	Empty,
	Simple,
	Rollup,
	Cube,
	Sets,
}
