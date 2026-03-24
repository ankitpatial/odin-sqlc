package ast

// Node is the central tagged union representing any SQL AST node.
// Uses Odin's discriminated union for exhaustive switch checking.
Node :: union {
	// Statements (DML)
	Select_Stmt,
	Insert_Stmt,
	Update_Stmt,
	Delete_Stmt,
	Truncate_Stmt,
	Explain_Stmt,
	Copy_Stmt,

	// Statements (DDL)
	Create_Table_Stmt,
	Create_Table_As_Stmt,
	Alter_Table_Stmt,
	Alter_Table_Cmd,
	Drop_Stmt,
	Create_Enum_Stmt,
	Alter_Enum_Stmt,
	Create_Function_Stmt,
	Function_Parameter,
	Drop_Function_Stmt,
	Create_Schema_Stmt,
	Drop_Schema_Stmt,
	Create_View_Stmt,
	Rename_Stmt,
	Comment_Stmt,
	Alter_Object_Schema_Stmt,
	Create_Extension_Stmt,
	Composite_Type_Stmt,
	Index_Stmt,
	Create_Seq_Stmt,
	Alter_Seq_Stmt,
	Grant_Stmt,
	Def_Elem,
	Role_Spec,
	Transaction_Stmt,
	Do_Stmt,
	Prepare_Stmt,
	Execute_Stmt,

	// Expressions
	A_Expr,
	A_Const,
	Bool_Expr,
	Func_Call,
	Type_Cast,
	Case_Expr,
	Case_When,
	Sub_Link,
	Coalesce_Expr,
	Null_Test,
	Boolean_Test,
	Row_Expr,
	A_Array_Expr,
	A_Indices,
	A_Indirection,
	Min_Max_Expr,
	Xml_Expr,
	Sql_Value_Function,
	Set_To_Default,
	Paren_Expr,

	// References
	Column_Ref,
	Param_Ref,
	Range_Var,
	Range_Subselect,
	Range_Function,
	Join_Expr,

	// Types / Names / Definitions
	Type_Name,
	Column_Def,
	Constraint,
	Res_Target,
	Alias,
	A_Star,
	Sort_By,
	Window_Def,
	Locking_Clause,
	Into_Clause,
	On_Conflict_Clause,
	Infer_Clause,
	Index_Elem,
	Multi_Assign_Ref,
	Grouping_Set,

	// Containers
	List,
	Raw_Stmt,

	// Scalars
	String_Node,
	Integer_Node,
	Float_Node,
	Boolean_Node,

	// CTE
	With_Clause,
	Common_Table_Expr,
}
