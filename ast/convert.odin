package ast

import "core:encoding/json"
import "core:mem"

// ────────────────────────────────────────────────────────────────
// JSON Extraction Helpers
// ────────────────────────────────────────────────────────────────

// Get a string field from a JSON object. Returns "" if missing.
get_str :: proc(obj: json.Object, key: string) -> string {
	val, ok := obj[key]
	if !ok { return "" }
	#partial switch v in val {
	case json.String:
		return v
	}
	return ""
}

// Get an i32 field. Returns 0 if missing.
get_i32 :: proc(obj: json.Object, key: string) -> i32 {
	val, ok := obj[key]
	if !ok { return 0 }
	#partial switch v in val {
	case json.Integer:
		return i32(v)
	case json.Float:
		return i32(v)
	}
	return 0
}

// Get an i64 field. Returns 0 if missing.
get_i64 :: proc(obj: json.Object, key: string) -> i64 {
	val, ok := obj[key]
	if !ok { return 0 }
	#partial switch v in val {
	case json.Integer:
		return i64(v)
	case json.Float:
		return i64(v)
	}
	return 0
}

// Get a u32 field. Returns 0 if missing.
get_u32 :: proc(obj: json.Object, key: string) -> u32 {
	val, ok := obj[key]
	if !ok { return 0 }
	#partial switch v in val {
	case json.Integer:
		return u32(v)
	}
	return 0
}

// Get a bool field. Returns false if missing.
get_bool :: proc(obj: json.Object, key: string) -> bool {
	val, ok := obj[key]
	if !ok { return false }
	#partial switch v in val {
	case json.Boolean:
		return bool(v)
	}
	return false
}

// Get a bool field with a custom default (for fields like inh that default to true).
get_bool_default :: proc(obj: json.Object, key: string, default_val: bool) -> bool {
	val, ok := obj[key]
	if !ok { return default_val }
	#partial switch v in val {
	case json.Boolean:
		return bool(v)
	}
	return default_val
}

// Get a byte field from a string (first byte). Returns 0 if missing.
get_byte :: proc(obj: json.Object, key: string) -> byte {
	s := get_str(obj, key)
	if len(s) == 0 { return 0 }
	return s[0]
}

// Get an i16 field. Returns 0 if missing.
get_i16 :: proc(obj: json.Object, key: string) -> i16 {
	return i16(get_i32(obj, key))
}

// Get a sub-object field. Returns nil if missing or wrong type.
get_obj :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	val, ok := obj[key]
	if !ok { return nil, false }
	inner, iok := val.(json.Object)
	return inner, iok
}

// Get an array field. Returns nil if missing.
get_arr :: proc(obj: json.Object, key: string) -> json.Array {
	val, ok := obj[key]
	if !ok { return nil }
	arr, aok := val.(json.Array)
	if !aok { return nil }
	return arr
}

// Get a string enum field. Returns "" if missing.
get_enum_str :: proc(obj: json.Object, key: string) -> string {
	return get_str(obj, key)
}

// ────────────────────────────────────────────────────────────────
// Node Extraction Helpers
//
// Key convention:
//   ^Node fields → JSON has discriminator wrapper {"TypeName": {...}}
//   ^SpecificType fields → JSON is direct (no wrapper)
//   [dynamic]^Node fields → JSON array of discriminated nodes
// ────────────────────────────────────────────────────────────────

// Unwrap a discriminated node: {"SelectStmt": {...}} → ("SelectStmt", {...})
unwrap_node :: proc(val: json.Value) -> (key: string, obj: json.Object, ok: bool) {
	wrapper, wok := val.(json.Object)
	if !wok { return "", nil, false }
	for k, v in wrapper {
		inner, iok := v.(json.Object)
		if iok {
			return k, inner, true
		}
	}
	return "", nil, false
}

// Get a ^Node child from a discriminated field.
get_node :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^Node {
	val, ok := obj[key]
	if !ok { return nil }
	return convert_node(val, allocator)
}

// Get a [dynamic]^Node from an array of discriminated nodes.
get_node_list :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> [dynamic]^Node {
	arr := get_arr(obj, key)
	if arr == nil { return nil }
	result := make([dynamic]^Node, 0, len(arr), allocator)
	for item in arr {
		node := convert_node(item, allocator)
		if node != nil {
			append(&result, node)
		}
	}
	return result
}

// Allocate a Node on the heap with a given variant value.
alloc_node :: proc(variant: Node, allocator: mem.Allocator) -> ^Node {
	node := new(Node, allocator)
	node^ = variant
	return node
}

// ────────────────────────────────────────────────────────────────
// Typed Pointer Helpers
//
// For struct fields like ^Range_Var, ^Alias, ^With_Clause, etc.
// These fields appear in JSON WITHOUT a discriminator wrapper.
// ────────────────────────────────────────────────────────────────

get_range_var :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^Range_Var {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	rv := new(Range_Var, allocator)
	rv^ = build_range_var(inner, allocator)
	return rv
}

get_alias :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^Alias {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	a := new(Alias, allocator)
	a^ = build_alias(inner, allocator)
	return a
}

get_with_clause :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^With_Clause {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	wc := new(With_Clause, allocator)
	wc^ = build_with_clause(inner, allocator)
	return wc
}

get_type_name :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^Type_Name {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	tn := new(Type_Name, allocator)
	tn^ = build_type_name(inner, allocator)
	fill_type_name_from_names(tn, inner, allocator)
	return tn
}

get_on_conflict :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^On_Conflict_Clause {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	oc := new(On_Conflict_Clause, allocator)
	oc^ = build_on_conflict_clause(inner, allocator)
	return oc
}

get_into_clause :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^Into_Clause {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	ic := new(Into_Clause, allocator)
	ic^ = build_into_clause(inner, allocator)
	return ic
}

get_window_def :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^Window_Def {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	wd := new(Window_Def, allocator)
	wd^ = build_window_def(inner, allocator)
	return wd
}

get_select_stmt :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^Select_Stmt {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	ss := new(Select_Stmt, allocator)
	ss^ = build_select_stmt(inner, allocator)
	return ss
}

// ────────────────────────────────────────────────────────────────
// Enum Conversion (JSON string → Odin enum)
// ────────────────────────────────────────────────────────────────

convert_set_operation :: proc(obj: json.Object, key: string) -> Set_Operation {
	switch get_enum_str(obj, key) {
	case "SETOP_UNION":     return .Union
	case "SETOP_INTERSECT": return .Intersect
	case "SETOP_EXCEPT":    return .Except
	}
	return .None
}

convert_bool_expr_type :: proc(obj: json.Object, key: string) -> Bool_Expr_Type {
	switch get_enum_str(obj, key) {
	case "AND_EXPR": return .And
	case "OR_EXPR":  return .Or
	case "NOT_EXPR": return .Not
	}
	return .And
}

convert_a_expr_kind :: proc(obj: json.Object, key: string) -> A_Expr_Kind {
	switch get_enum_str(obj, key) {
	case "AEXPR_OP":               return .Op
	case "AEXPR_OP_ANY":           return .Op_Any
	case "AEXPR_OP_ALL":           return .Op_All
	case "AEXPR_DISTINCT":         return .Distinct
	case "AEXPR_NOT_DISTINCT":     return .Not_Distinct
	case "AEXPR_NULLIF":           return .Nullif
	case "AEXPR_IN":               return .In
	case "AEXPR_LIKE":             return .Like
	case "AEXPR_ILIKE":            return .ILike
	case "AEXPR_SIMILAR":          return .Similar
	case "AEXPR_BETWEEN":          return .Between
	case "AEXPR_NOT_BETWEEN":      return .Not_Between
	case "AEXPR_BETWEEN_SYM":      return .Between_Sym
	case "AEXPR_NOT_BETWEEN_SYM":  return .Not_Between_Sym
	}
	return .Undefined
}

convert_sub_link_type :: proc(obj: json.Object, key: string) -> Sub_Link_Type {
	switch get_enum_str(obj, key) {
	case "EXISTS_SUBLINK":      return .Exists
	case "ALL_SUBLINK":         return .All
	case "ANY_SUBLINK":         return .Any
	case "ROWCOMPARE_SUBLINK":  return .Row_Compare
	case "EXPR_SUBLINK":        return .Expr
	case "MULTIEXPR_SUBLINK":   return .Multiexpr
	case "ARRAY_SUBLINK":       return .Array
	case "CTE_SUBLINK":         return .CTE
	}
	return .Exists
}

convert_null_test_type :: proc(obj: json.Object, key: string) -> Null_Test_Type {
	switch get_enum_str(obj, key) {
	case "IS_NULL":     return .Is_Null
	case "IS_NOT_NULL": return .Is_Not_Null
	}
	return .Is_Null
}

convert_sort_by_dir :: proc(obj: json.Object, key: string) -> Sort_By_Dir {
	switch get_enum_str(obj, key) {
	case "SORTBY_ASC":   return .Asc
	case "SORTBY_DESC":  return .Desc
	case "SORTBY_USING": return .Using
	}
	return .Default
}

convert_sort_by_nulls :: proc(obj: json.Object, key: string) -> Sort_By_Nulls {
	switch get_enum_str(obj, key) {
	case "SORTBY_NULLS_FIRST": return .First
	case "SORTBY_NULLS_LAST":  return .Last
	}
	return .Default
}

convert_join_type :: proc(obj: json.Object, key: string) -> Join_Type {
	switch get_enum_str(obj, key) {
	case "JOIN_INNER": return .Inner
	case "JOIN_LEFT":  return .Left
	case "JOIN_FULL":  return .Full
	case "JOIN_RIGHT": return .Right
	case "JOIN_SEMI":  return .Semi
	case "JOIN_ANTI":  return .Anti
	}
	return .Inner
}

convert_constraint_type :: proc(obj: json.Object, key: string) -> Constraint_Type {
	switch get_enum_str(obj, key) {
	case "CONSTR_NULL":               return .Null
	case "CONSTR_NOTNULL":            return .Not_Null
	case "CONSTR_DEFAULT":            return .Default
	case "CONSTR_IDENTITY":           return .Identity
	case "CONSTR_GENERATED":          return .Generated
	case "CONSTR_CHECK":              return .Check
	case "CONSTR_PRIMARY":            return .Primary_Key
	case "CONSTR_UNIQUE":             return .Unique
	case "CONSTR_EXCLUSION":          return .Exclusion
	case "CONSTR_FOREIGN":            return .Foreign_Key
	case "CONSTR_ATTR_DEFERRABLE":    return .Attr_Deferrable
	case "CONSTR_ATTR_NOT_DEFERRABLE": return .Attr_Not_Deferrable
	case "CONSTR_ATTR_DEFERRED":      return .Attr_Deferred
	case "CONSTR_ATTR_IMMEDIATE":     return .Attr_Immediate
	}
	return .Null
}

convert_object_type :: proc(obj: json.Object, key: string) -> Object_Type {
	switch get_enum_str(obj, key) {
	case "OBJECT_TABLE":             return .Table
	case "OBJECT_SEQUENCE":          return .Sequence
	case "OBJECT_VIEW":              return .View
	case "OBJECT_MATVIEW":           return .Materialized_View
	case "OBJECT_INDEX":             return .Index
	case "OBJECT_FOREIGN_TABLE":     return .Foreign_Table
	case "OBJECT_TYPE":              return .Type
	case "OBJECT_SCHEMA":            return .Schema
	case "OBJECT_FUNCTION":          return .Function
	case "OBJECT_PROCEDURE":         return .Procedure
	case "OBJECT_AGGREGATE":         return .Aggregate
	case "OBJECT_OPERATOR":          return .Operator
	case "OBJECT_EXTENSION":         return .Extension
	case "OBJECT_POLICY":            return .Policy
	case "OBJECT_RULE":              return .Rule
	case "OBJECT_TRIGGER":           return .Trigger
	case "OBJECT_EVENT_TRIGGER":     return .Event_Trigger
	case "OBJECT_COLLATION":         return .Collation
	case "OBJECT_CONVERSION":        return .Conversion
	case "OBJECT_DOMAIN":            return .Domain
	case "OBJECT_ACCESS_METHOD":     return .Access_Method
	case "OBJECT_CAST":              return .Cast
	case "OBJECT_COLUMN":            return .Table  // COMMENT ON COLUMN uses Table context
	}
	return .Table
}

convert_drop_behavior :: proc(obj: json.Object, key: string) -> Drop_Behavior {
	switch get_enum_str(obj, key) {
	case "DROP_CASCADE": return .Cascade
	}
	return .Restrict
}

convert_on_conflict_action :: proc(obj: json.Object, key: string) -> On_Conflict_Action {
	switch get_enum_str(obj, key) {
	case "ONCONFLICT_NOTHING": return .Nothing
	case "ONCONFLICT_UPDATE":  return .Update
	}
	return .None
}

convert_limit_option :: proc(obj: json.Object, key: string) -> Limit_Option {
	switch get_enum_str(obj, key) {
	case "LIMIT_OPTION_COUNT":     return .Count
	case "LIMIT_OPTION_PERCENT":   return .Percent
	case "LIMIT_OPTION_WITH_TIES": return .With_Ties
	}
	return .Default
}

convert_func_param_mode :: proc(obj: json.Object, key: string) -> Func_Param_Mode {
	switch get_enum_str(obj, key) {
	case "FUNC_PARAM_IN":       return .In
	case "FUNC_PARAM_OUT":      return .Out
	case "FUNC_PARAM_INOUT":    return .In_Out
	case "FUNC_PARAM_VARIADIC": return .Variadic
	case "FUNC_PARAM_TABLE":    return .Table
	case "FUNC_PARAM_DEFAULT":  return .Default
	}
	return .In
}

convert_alter_table_type :: proc(obj: json.Object, key: string) -> Alter_Table_Type {
	switch get_enum_str(obj, key) {
	case "AT_AddColumn":              return .Add_Column
	case "AT_DropColumn":             return .Drop_Column
	case "AT_AlterColumnType":        return .Alter_Column_Type
	case "AT_ColumnDefault":          return .Alter_Column_Set_Default
	case "AT_DropNotNull":            return .Alter_Column_Drop_Not_Null
	case "AT_SetNotNull":             return .Alter_Column_Set_Not_Null
	case "AT_AddConstraint":          return .Add_Constraint
	case "AT_DropConstraint":         return .Drop_Constraint
	case "AT_SetSchema":              return .Set_Schema
	case "AT_ChangeOwner":            return .Set_Owner
	case "AT_AddIndex":               return .Add_Index
	}
	return .Add_Column
}

convert_def_elem_action :: proc(obj: json.Object, key: string) -> Def_Elem_Action {
	switch get_enum_str(obj, key) {
	case "DEFELEM_SET":   return .Set
	case "DEFELEM_ADD":   return .Add
	case "DEFELEM_DROP":  return .Drop
	}
	return .Unspec
}

convert_grouping_set_kind :: proc(obj: json.Object, key: string) -> Grouping_Set_Kind {
	switch get_enum_str(obj, key) {
	case "GROUPING_SET_EMPTY":  return .Empty
	case "GROUPING_SET_SIMPLE": return .Simple
	case "GROUPING_SET_ROLLUP": return .Rollup
	case "GROUPING_SET_CUBE":   return .Cube
	case "GROUPING_SET_SETS":   return .Sets
	}
	return .Empty
}

// ────────────────────────────────────────────────────────────────
// Scalar / Leaf Node Converters
// ────────────────────────────────────────────────────────────────

build_string_node :: proc(obj: json.Object) -> String_Node {
	return String_Node{sval = get_str(obj, "sval")}
}

build_integer_node :: proc(obj: json.Object) -> Integer_Node {
	return Integer_Node{ival = get_i64(obj, "ival")}
}

build_float_node :: proc(obj: json.Object) -> Float_Node {
	return Float_Node{fval = get_str(obj, "fval")}
}

build_boolean_node :: proc(obj: json.Object) -> Boolean_Node {
	return Boolean_Node{boolval = get_bool(obj, "boolval")}
}

build_a_star :: proc(obj: json.Object) -> A_Star {
	return A_Star{location = get_i32(obj, "location")}
}

build_param_ref :: proc(obj: json.Object) -> Param_Ref {
	return Param_Ref{
		number   = get_i32(obj, "number"),
		location = get_i32(obj, "location"),
	}
}

build_a_const :: proc(obj: json.Object, allocator: mem.Allocator) -> A_Const {
	c := A_Const{
		location = get_i32(obj, "location"),
	}

	// Protobuf oneof — check which value field is present
	if ival_obj, ival_ok := get_obj(obj, "ival"); ival_ok {
		c.type = .Integer
		c.ival = get_i64(ival_obj, "ival")
	} else if sval_obj, sval_ok := get_obj(obj, "sval"); sval_ok {
		c.type = .String
		c.sval = get_str(sval_obj, "sval")
	} else if fval_obj, fval_ok := get_obj(obj, "fval"); fval_ok {
		c.type = .Float
		c.fval = get_str(fval_obj, "fval")
	} else if bval_obj, bval_ok := get_obj(obj, "boolval"); bval_ok {
		c.type = .Boolean
		c.bval = get_bool(bval_obj, "boolval")
	} else if bs_obj, bs_ok := get_obj(obj, "bsval"); bs_ok {
		c.type = .Bit_String
		c.bsval = get_str(bs_obj, "bsval")
	} else if get_bool(obj, "isnull") {
		c.type = .Null
	}

	return c
}

// ────────────────────────────────────────────────────────────────
// Expression Converters
// ────────────────────────────────────────────────────────────────

build_a_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> A_Expr {
	return A_Expr{
		kind     = convert_a_expr_kind(obj, "kind"),
		name     = get_node_list(obj, "name", allocator),
		lexpr    = get_node(obj, "lexpr", allocator),
		rexpr    = get_node(obj, "rexpr", allocator),
		location = get_i32(obj, "location"),
	}
}

build_bool_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Bool_Expr {
	return Bool_Expr{
		boolop   = convert_bool_expr_type(obj, "boolop"),
		args     = get_node_list(obj, "args", allocator),
		location = get_i32(obj, "location"),
	}
}

build_func_call :: proc(obj: json.Object, allocator: mem.Allocator) -> Func_Call {
	return Func_Call{
		funcname         = get_node_list(obj, "funcname", allocator),
		args             = get_node_list(obj, "args", allocator),
		agg_order        = get_node_list(obj, "aggOrder", allocator),
		agg_filter       = get_node(obj, "aggFilter", allocator),
		over             = get_window_def(obj, "over", allocator),
		agg_within_group = get_bool(obj, "aggWithinGroup"),
		agg_star         = get_bool(obj, "aggStar"),
		agg_distinct     = get_bool(obj, "aggDistinct"),
		func_variadic    = get_bool(obj, "funcVariadic"),
		funcformat       = get_i32(obj, "funcformat"),
		location         = get_i32(obj, "location"),
	}
}

build_type_cast :: proc(obj: json.Object, allocator: mem.Allocator) -> Type_Cast {
	return Type_Cast{
		arg       = get_node(obj, "arg", allocator),
		type_name = get_type_name(obj, "typeName", allocator),
		location  = get_i32(obj, "location"),
	}
}

build_case_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Case_Expr {
	return Case_Expr{
		casetype   = get_u32(obj, "casetype"),
		casecollid = get_u32(obj, "casecollid"),
		arg        = get_node(obj, "arg", allocator),
		args       = get_node_list(obj, "args", allocator),
		defresult  = get_node(obj, "defresult", allocator),
		location   = get_i32(obj, "location"),
	}
}

build_case_when :: proc(obj: json.Object, allocator: mem.Allocator) -> Case_When {
	return Case_When{
		expr     = get_node(obj, "expr", allocator),
		result   = get_node(obj, "result", allocator),
		location = get_i32(obj, "location"),
	}
}

build_sub_link :: proc(obj: json.Object, allocator: mem.Allocator) -> Sub_Link {
	return Sub_Link{
		sub_link_type = convert_sub_link_type(obj, "subLinkType"),
		testexpr      = get_node(obj, "testexpr", allocator),
		oper_name     = get_node_list(obj, "operName", allocator),
		subselect     = get_node(obj, "subselect", allocator),
		location      = get_i32(obj, "location"),
	}
}

build_coalesce_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Coalesce_Expr {
	return Coalesce_Expr{
		coalescetype   = get_u32(obj, "coalescetype"),
		coalescecollid = get_u32(obj, "coalescecollid"),
		args           = get_node_list(obj, "args", allocator),
		location       = get_i32(obj, "location"),
	}
}

build_null_test :: proc(obj: json.Object, allocator: mem.Allocator) -> Null_Test {
	return Null_Test{
		arg          = get_node(obj, "arg", allocator),
		nulltesttype = convert_null_test_type(obj, "nulltesttype"),
		argisrow     = get_bool(obj, "argisrow"),
		location     = get_i32(obj, "location"),
	}
}

build_boolean_test :: proc(obj: json.Object, allocator: mem.Allocator) -> Boolean_Test {
	return Boolean_Test{
		arg          = get_node(obj, "arg", allocator),
		booltesttype = get_i32(obj, "booltesttype"),
		location     = get_i32(obj, "location"),
	}
}

build_row_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Row_Expr {
	return Row_Expr{
		args       = get_node_list(obj, "args", allocator),
		row_typeid = get_u32(obj, "rowTypeid"),
		row_format = get_i32(obj, "rowFormat"),
		colnames   = get_node_list(obj, "colnames", allocator),
		location   = get_i32(obj, "location"),
	}
}

build_a_array_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> A_Array_Expr {
	return A_Array_Expr{
		elements = get_node_list(obj, "elements", allocator),
		location = get_i32(obj, "location"),
	}
}

build_a_indices :: proc(obj: json.Object, allocator: mem.Allocator) -> A_Indices {
	return A_Indices{
		is_slice = get_bool(obj, "isSlice"),
		lidx     = get_node(obj, "lidx", allocator),
		uidx     = get_node(obj, "uidx", allocator),
	}
}

build_a_indirection :: proc(obj: json.Object, allocator: mem.Allocator) -> A_Indirection {
	return A_Indirection{
		arg         = get_node(obj, "arg", allocator),
		indirection = get_node_list(obj, "indirection", allocator),
	}
}

build_min_max_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Min_Max_Expr {
	return Min_Max_Expr{
		minmaxtype   = get_u32(obj, "minmaxtype"),
		minmaxcollid = get_u32(obj, "minmaxcollid"),
		inputcollid  = get_u32(obj, "inputcollid"),
		op           = get_i32(obj, "op"),
		args         = get_node_list(obj, "args", allocator),
		location     = get_i32(obj, "location"),
	}
}

build_xml_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Xml_Expr {
	return Xml_Expr{
		op         = get_i32(obj, "op"),
		name       = get_str(obj, "name"),
		named_args = get_node_list(obj, "namedArgs", allocator),
		arg_names  = get_node_list(obj, "argNames", allocator),
		args       = get_node_list(obj, "args", allocator),
		xmloption  = get_i32(obj, "xmloption"),
		indent     = get_bool(obj, "indent"),
		type_id    = get_u32(obj, "typeId"),
		typmod     = get_i32(obj, "typmod"),
		location   = get_i32(obj, "location"),
	}
}

build_sql_value_function :: proc(obj: json.Object) -> Sql_Value_Function {
	return Sql_Value_Function{
		op       = get_i32(obj, "op"),
		type_id  = get_u32(obj, "typeId"),
		typmod   = get_i32(obj, "typmod"),
		location = get_i32(obj, "location"),
	}
}

build_set_to_default :: proc(obj: json.Object) -> Set_To_Default {
	return Set_To_Default{
		type_id   = get_u32(obj, "typeId"),
		typmod    = get_i32(obj, "typmod"),
		collation = get_u32(obj, "collation"),
		location  = get_i32(obj, "location"),
	}
}

build_paren_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Paren_Expr {
	return Paren_Expr{
		arg      = get_node(obj, "arg", allocator),
		location = get_i32(obj, "location"),
	}
}

// ────────────────────────────────────────────────────────────────
// Reference / Type / Container Converters
// ────────────────────────────────────────────────────────────────

build_column_ref :: proc(obj: json.Object, allocator: mem.Allocator) -> Column_Ref {
	return Column_Ref{
		fields   = get_node_list(obj, "fields", allocator),
		location = get_i32(obj, "location"),
	}
}

build_range_var :: proc(obj: json.Object, allocator: mem.Allocator) -> Range_Var {
	return Range_Var{
		catalogname    = get_str(obj, "catalogname"),
		schemaname     = get_str(obj, "schemaname"),
		relname        = get_str(obj, "relname"),
		inh            = get_bool_default(obj, "inh", true),  // PostgreSQL default: inherit
		relpersistence = get_byte(obj, "relpersistence"),
		alias          = get_alias(obj, "alias", allocator),
		location       = get_i32(obj, "location"),
	}
}

build_res_target :: proc(obj: json.Object, allocator: mem.Allocator) -> Res_Target {
	return Res_Target{
		name        = get_str(obj, "name"),
		indirection = get_node_list(obj, "indirection", allocator),
		val         = get_node(obj, "val", allocator),
		location    = get_i32(obj, "location"),
	}
}

build_type_name :: proc(obj: json.Object, allocator: mem.Allocator) -> Type_Name {
	return Type_Name{
		array_bounds = get_node_list(obj, "arrayBounds", allocator),
		set_of       = get_bool(obj, "setof"),
		pct_type     = get_bool(obj, "pctType"),
		typmods      = get_node_list(obj, "typmods", allocator),
		location     = get_i32(obj, "location"),
	}
}

// Parse TypeName.names (list of String nodes) into catalog/schema/name.
// Called after build_type_name to fill in the name fields.
fill_type_name_from_names :: proc(tn: ^Type_Name, obj: json.Object, allocator: mem.Allocator) {
	names := get_node_list(obj, "names", allocator)
	parts := make([dynamic]string, 0, 3, context.temp_allocator)
	for n in names {
		if n == nil { continue }
		if s, ok := n^.(String_Node); ok {
			append(&parts, s.sval)
		}
	}
	switch len(parts) {
	case 1:
		tn.name = parts[0]
	case 2:
		tn.schema = parts[0]
		tn.name   = parts[1]
	case 3:
		tn.catalog = parts[0]
		tn.schema  = parts[1]
		tn.name    = parts[2]
	}
}

build_alias :: proc(obj: json.Object, allocator: mem.Allocator) -> Alias {
	return Alias{
		aliasname = get_str(obj, "aliasname"),
		colnames  = get_node_list(obj, "colnames", allocator),
	}
}

build_sort_by :: proc(obj: json.Object, allocator: mem.Allocator) -> Sort_By {
	return Sort_By{
		node         = get_node(obj, "node", allocator),
		sortby_dir   = convert_sort_by_dir(obj, "sortbyDir"),
		sortby_nulls = convert_sort_by_nulls(obj, "sortbyNulls"),
		use_op       = get_node_list(obj, "useOp", allocator),
		location     = get_i32(obj, "location"),
	}
}

build_window_def :: proc(obj: json.Object, allocator: mem.Allocator) -> Window_Def {
	return Window_Def{
		name             = get_str(obj, "name"),
		refname          = get_str(obj, "refname"),
		partition_clause = get_node_list(obj, "partitionClause", allocator),
		order_clause     = get_node_list(obj, "orderClause", allocator),
		frame_options    = get_i32(obj, "frameOptions"),
		start_offset     = get_node(obj, "startOffset", allocator),
		end_offset       = get_node(obj, "endOffset", allocator),
		location         = get_i32(obj, "location"),
	}
}

build_locking_clause :: proc(obj: json.Object, allocator: mem.Allocator) -> Locking_Clause {
	strength: Lock_Clause_Strength
	switch get_enum_str(obj, "strength") {
	case "LCS_FORKEYSHARE":    strength = .For_Key_Share
	case "LCS_FORSHARE":       strength = .For_Share
	case "LCS_FORNOKEYUPDATE": strength = .For_No_Key_Update
	case "LCS_FORUPDATE":      strength = .For_Update
	}
	return Locking_Clause{
		locked_rels = get_node_list(obj, "lockedRels", allocator),
		strength    = strength,
		wait_policy = get_i32(obj, "waitPolicy"),
	}
}

build_list :: proc(obj: json.Object, allocator: mem.Allocator) -> List {
	return List{
		items = get_node_list(obj, "items", allocator),
	}
}

build_with_clause :: proc(obj: json.Object, allocator: mem.Allocator) -> With_Clause {
	return With_Clause{
		ctes      = get_node_list(obj, "ctes", allocator),
		recursive = get_bool(obj, "recursive"),
		location  = get_i32(obj, "location"),
	}
}

build_common_table_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Common_Table_Expr {
	return Common_Table_Expr{
		ctename          = get_str(obj, "ctename"),
		aliascolnames    = get_node_list(obj, "aliascolnames", allocator),
		ctematerialized  = get_i32(obj, "ctematerialized"),
		ctequery         = get_node(obj, "ctequery", allocator),
		location         = get_i32(obj, "location"),
		cterecursive     = get_bool(obj, "cterecursive"),
		cterefcount      = get_i32(obj, "cterefcount"),
		ctecolnames      = get_node_list(obj, "ctecolnames", allocator),
		ctecoltypes      = get_node_list(obj, "ctecoltypes", allocator),
		ctecoltypmods    = get_node_list(obj, "ctecoltypmods", allocator),
		ctecolcollations = get_node_list(obj, "ctecolcollations", allocator),
	}
}

build_on_conflict_clause :: proc(obj: json.Object, allocator: mem.Allocator) -> On_Conflict_Clause {
	return On_Conflict_Clause{
		action       = convert_on_conflict_action(obj, "action"),
		infer        = get_node(obj, "infer", allocator),
		target_list  = get_node_list(obj, "targetList", allocator),
		where_clause = get_node(obj, "whereClause", allocator),
		location     = get_i32(obj, "location"),
	}
}

build_infer_clause :: proc(obj: json.Object, allocator: mem.Allocator) -> Infer_Clause {
	return Infer_Clause{
		index_elems  = get_node_list(obj, "indexElems", allocator),
		where_clause = get_node(obj, "whereClause", allocator),
		conname      = get_str(obj, "conname"),
		location     = get_i32(obj, "location"),
	}
}

build_index_elem :: proc(obj: json.Object, allocator: mem.Allocator) -> Index_Elem {
	return Index_Elem{
		name           = get_str(obj, "name"),
		expr           = get_node(obj, "expr", allocator),
		indexcolname   = get_str(obj, "indexcolname"),
		collation      = get_node_list(obj, "collation", allocator),
		opclass        = get_node_list(obj, "opclass", allocator),
		opclassopts    = get_node_list(obj, "opclassopts", allocator),
		ordering       = convert_sort_by_dir(obj, "ordering"),
		nulls_ordering = convert_sort_by_nulls(obj, "nullsOrdering"),
	}
}

build_multi_assign_ref :: proc(obj: json.Object, allocator: mem.Allocator) -> Multi_Assign_Ref {
	return Multi_Assign_Ref{
		source   = get_node(obj, "source", allocator),
		colno    = get_i32(obj, "colno"),
		ncolumns = get_i32(obj, "ncolumns"),
	}
}

build_grouping_set :: proc(obj: json.Object, allocator: mem.Allocator) -> Grouping_Set {
	return Grouping_Set{
		kind     = convert_grouping_set_kind(obj, "kind"),
		content  = get_node_list(obj, "content", allocator),
		location = get_i32(obj, "location"),
	}
}

build_into_clause :: proc(obj: json.Object, allocator: mem.Allocator) -> Into_Clause {
	return Into_Clause{
		rel            = get_range_var(obj, "rel", allocator),
		col_names      = get_node_list(obj, "colNames", allocator),
		access_method  = get_str(obj, "accessMethod"),
		options        = get_node_list(obj, "options", allocator),
		on_commit      = get_i32(obj, "onCommit"),
		tablespacename = get_str(obj, "tableSpaceName"),
		view_query     = get_node(obj, "viewQuery", allocator),
		skip_data      = get_bool(obj, "skipData"),
	}
}

build_column_def :: proc(obj: json.Object, allocator: mem.Allocator) -> Column_Def {
	return Column_Def{
		colname        = get_str(obj, "colname"),
		type_name      = get_type_name(obj, "typeName", allocator),
		compression    = get_str(obj, "compression"),
		inhcount       = get_i32(obj, "inhcount"),
		is_local       = get_bool(obj, "is_local"),
		is_not_null    = get_bool(obj, "is_not_null"),
		is_from_type   = get_bool(obj, "is_from_type"),
		storage        = get_byte(obj, "storage"),
		raw_default    = get_node(obj, "rawDefault", allocator),
		cooked_default = get_node(obj, "cookedDefault", allocator),
		identity       = get_byte(obj, "identity"),
		generated      = get_byte(obj, "generated"),
		coll_clause    = get_node(obj, "collClause", allocator),
		coll_oid       = get_u32(obj, "collOid"),
		constraints    = get_node_list(obj, "constraints", allocator),
		fdwoptions     = get_node_list(obj, "fdwoptions", allocator),
		location       = get_i32(obj, "location"),
	}
}

build_constraint :: proc(obj: json.Object, allocator: mem.Allocator) -> Constraint {
	return Constraint{
		contype              = convert_constraint_type(obj, "contype"),
		conname              = get_str(obj, "conname"),
		deferrable           = get_bool(obj, "deferrable"),
		initdeferred         = get_bool(obj, "initdeferred"),
		location             = get_i32(obj, "location"),
		is_no_inherit        = get_bool(obj, "isNoInherit"),
		raw_expr             = get_node(obj, "rawExpr", allocator),
		cooked_expr          = get_str(obj, "cookedExpr"),
		generated_when       = get_byte(obj, "generatedWhen"),
		keys                 = get_node_list(obj, "keys", allocator),
		including            = get_node_list(obj, "including", allocator),
		exclusions           = get_node_list(obj, "exclusions", allocator),
		options              = get_node_list(obj, "options", allocator),
		indexname             = get_str(obj, "indexname"),
		indexspace            = get_str(obj, "indexspace"),
		reset_default_tblspc = get_bool(obj, "resetDefaultTblspc"),
		access_method        = get_str(obj, "accessMethod"),
		where_clause         = get_node(obj, "whereClause", allocator),
		pktable              = get_range_var(obj, "pktable", allocator),
		fk_attrs             = get_node_list(obj, "fkAttrs", allocator),
		pk_attrs             = get_node_list(obj, "pkAttrs", allocator),
		fk_matchtype         = get_byte(obj, "fkMatchtype"),
		fk_upd_action        = get_byte(obj, "fkUpdAction"),
		fk_del_action        = get_byte(obj, "fkDelAction"),
		fk_del_set_cols      = get_node_list(obj, "fkDelSetCols", allocator),
		old_conpfeqop        = get_node_list(obj, "oldConpfeqop", allocator),
		old_pktable_oid      = get_u32(obj, "oldPktableOid"),
		skip_validation      = get_bool(obj, "skipValidation"),
		initially_valid      = get_bool(obj, "initiallyValid"),
	}
}

// ────────────────────────────────────────────────────────────────
// Statement Converters (DML)
// ────────────────────────────────────────────────────────────────

build_select_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Select_Stmt {
	return Select_Stmt{
		distinct_clause = get_node_list(obj, "distinctClause", allocator),
		into_clause     = get_node(obj, "intoClause", allocator),
		target_list     = get_node_list(obj, "targetList", allocator),
		from_clause     = get_node_list(obj, "fromClause", allocator),
		where_clause    = get_node(obj, "whereClause", allocator),
		group_clause    = get_node_list(obj, "groupClause", allocator),
		group_distinct  = get_bool(obj, "groupDistinct"),
		having_clause   = get_node(obj, "havingClause", allocator),
		window_clause   = get_node_list(obj, "windowClause", allocator),
		values_lists    = convert_values_lists(obj, allocator),
		sort_clause     = get_node_list(obj, "sortClause", allocator),
		limit_offset    = get_node(obj, "limitOffset", allocator),
		limit_count     = get_node(obj, "limitCount", allocator),
		limit_option    = convert_limit_option(obj, "limitOption"),
		locking_clause  = get_node_list(obj, "lockingClause", allocator),
		with_clause     = get_with_clause(obj, "withClause", allocator),
		op              = convert_set_operation(obj, "op"),
		all             = get_bool(obj, "all"),
		larg            = get_select_stmt(obj, "larg", allocator),
		rarg            = get_select_stmt(obj, "rarg", allocator),
	}
}

// Convert values_lists: JSON is array of List nodes → [dynamic][dynamic]^Node
convert_values_lists :: proc(obj: json.Object, allocator: mem.Allocator) -> [dynamic][dynamic]^Node {
	arr := get_arr(obj, "valuesLists")
	if arr == nil { return nil }
	result := make([dynamic][dynamic]^Node, 0, len(arr), allocator)
	for item in arr {
		node := convert_node(item, allocator)
		if node == nil { continue }
		if list_val, ok := node^.(List); ok {
			append(&result, list_val.items)
		}
	}
	return result
}

build_insert_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Insert_Stmt {
	return Insert_Stmt{
		relation       = get_range_var(obj, "relation", allocator),
		cols           = get_node_list(obj, "cols", allocator),
		select_stmt    = get_node(obj, "selectStmt", allocator),
		on_conflict    = get_on_conflict(obj, "onConflictClause", allocator),
		returning_list = get_node_list(obj, "returningList", allocator),
		with_clause    = get_with_clause(obj, "withClause", allocator),
		override       = get_i32(obj, "override"),
	}
}

build_update_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Update_Stmt {
	return Update_Stmt{
		relation       = get_range_var(obj, "relation", allocator),
		target_list    = get_node_list(obj, "targetList", allocator),
		where_clause   = get_node(obj, "whereClause", allocator),
		from_clause    = get_node_list(obj, "fromClause", allocator),
		returning_list = get_node_list(obj, "returningList", allocator),
		with_clause    = get_with_clause(obj, "withClause", allocator),
	}
}

build_delete_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Delete_Stmt {
	return Delete_Stmt{
		relation       = get_range_var(obj, "relation", allocator),
		using_clause   = get_node_list(obj, "usingClause", allocator),
		where_clause   = get_node(obj, "whereClause", allocator),
		returning_list = get_node_list(obj, "returningList", allocator),
		with_clause    = get_with_clause(obj, "withClause", allocator),
	}
}

build_truncate_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Truncate_Stmt {
	return Truncate_Stmt{
		relations    = get_node_list(obj, "relations", allocator),
		restart_seqs = get_bool(obj, "restartSeqs"),
		behavior     = convert_drop_behavior(obj, "behavior"),
	}
}

build_explain_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Explain_Stmt {
	return Explain_Stmt{
		query   = get_node(obj, "query", allocator),
		options = get_node_list(obj, "options", allocator),
	}
}

build_copy_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Copy_Stmt {
	return Copy_Stmt{
		relation     = get_range_var(obj, "relation", allocator),
		query        = get_node(obj, "query", allocator),
		attlist      = get_node_list(obj, "attlist", allocator),
		is_from      = get_bool(obj, "isFrom"),
		is_program   = get_bool(obj, "isProgram"),
		filename     = get_str(obj, "filename"),
		options      = get_node_list(obj, "options", allocator),
		where_clause = get_node(obj, "whereClause", allocator),
	}
}

build_range_subselect :: proc(obj: json.Object, allocator: mem.Allocator) -> Range_Subselect {
	return Range_Subselect{
		lateral  = get_bool(obj, "lateral"),
		subquery = get_node(obj, "subquery", allocator),
		alias    = get_alias(obj, "alias", allocator),
	}
}

build_range_function :: proc(obj: json.Object, allocator: mem.Allocator) -> Range_Function {
	return Range_Function{
		lateral     = get_bool(obj, "lateral"),
		ordinality  = get_bool(obj, "ordinality"),
		is_rowsfrom = get_bool(obj, "isRowsfrom"),
		functions   = get_node_list(obj, "functions", allocator),
		alias       = get_alias(obj, "alias", allocator),
		coldeflist  = get_node_list(obj, "coldeflist", allocator),
	}
}

build_join_expr :: proc(obj: json.Object, allocator: mem.Allocator) -> Join_Expr {
	return Join_Expr{
		jointype         = convert_join_type(obj, "jointype"),
		is_natural       = get_bool(obj, "isNatural"),
		larg             = get_node(obj, "larg", allocator),
		rarg             = get_node(obj, "rarg", allocator),
		using_clause     = get_node_list(obj, "usingClause", allocator),
		join_using_alias = get_alias(obj, "joinUsingAlias", allocator),
		quals            = get_node(obj, "quals", allocator),
		alias            = get_alias(obj, "alias", allocator),
	}
}

// ────────────────────────────────────────────────────────────────
// DDL Statement Converters (generic — translate.odin overrides some)
// ────────────────────────────────────────────────────────────────

build_create_table_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Create_Table_Stmt {
	return Create_Table_Stmt{
		relation       = get_range_var(obj, "relation", allocator),
		table_elts     = get_node_list(obj, "tableElts", allocator),
		inh_relations  = get_node_list(obj, "inhRelations", allocator),
		partbound      = get_node(obj, "partbound", allocator),
		partspec       = get_node(obj, "partspec", allocator),
		of_typename    = get_type_name(obj, "ofTypename", allocator),
		constraints    = get_node_list(obj, "constraints", allocator),
		options        = get_node_list(obj, "options", allocator),
		oncommit       = get_i32(obj, "oncommit"),
		tablespacename = get_str(obj, "tablespacename"),
		access_method  = get_str(obj, "accessMethod"),
		if_not_exists  = get_bool(obj, "ifNotExists"),
	}
}

build_alter_table_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Alter_Table_Stmt {
	return Alter_Table_Stmt{
		relation   = get_range_var(obj, "relation", allocator),
		cmds       = get_node_list(obj, "cmds", allocator),
		objtype    = convert_object_type(obj, "objtype"),
		missing_ok = get_bool(obj, "missingOk"),
	}
}

build_alter_table_cmd :: proc(obj: json.Object, allocator: mem.Allocator) -> Alter_Table_Cmd {
	return Alter_Table_Cmd{
		subtype    = convert_alter_table_type(obj, "subtype"),
		name       = get_str(obj, "name"),
		num        = get_i16(obj, "num"),
		newowner   = get_node(obj, "newowner", allocator),
		def        = get_node(obj, "def", allocator),
		behavior   = convert_drop_behavior(obj, "behavior"),
		missing_ok = get_bool(obj, "missingOk"),
		recurse    = get_bool(obj, "recurse"),
	}
}

build_drop_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Drop_Stmt {
	return Drop_Stmt{
		objects     = get_node_list(obj, "objects", allocator),
		remove_type = convert_object_type(obj, "removeType"),
		behavior    = convert_drop_behavior(obj, "behavior"),
		missing_ok  = get_bool(obj, "missingOk"),
		concurrent  = get_bool(obj, "concurrent"),
	}
}

build_create_enum_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Create_Enum_Stmt {
	return Create_Enum_Stmt{
		type_name = get_node_list(obj, "typeName", allocator),
		vals      = get_node_list(obj, "vals", allocator),
	}
}

build_alter_enum_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Alter_Enum_Stmt {
	return Alter_Enum_Stmt{
		type_name              = get_node_list(obj, "typeName", allocator),
		old_val                = get_str(obj, "oldVal"),
		new_val                = get_str(obj, "newVal"),
		new_val_neighbor       = get_str(obj, "newValNeighbor"),
		new_val_is_after       = get_bool(obj, "newValIsAfter"),
		skip_if_new_val_exists = get_bool(obj, "skipIfNewValExists"),
	}
}

build_create_function_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Create_Function_Stmt {
	return Create_Function_Stmt{
		is_procedure = get_bool(obj, "isProcedure"),
		replace      = get_bool(obj, "replace"),
		funcname     = get_node_list(obj, "funcname", allocator),
		parameters   = get_node_list(obj, "parameters", allocator),
		return_type  = get_type_name(obj, "returnType", allocator),
		options      = get_node_list(obj, "options", allocator),
		sql_body     = get_node(obj, "sqlBody", allocator),
	}
}

build_function_parameter :: proc(obj: json.Object, allocator: mem.Allocator) -> Function_Parameter {
	return Function_Parameter{
		name     = get_str(obj, "name"),
		arg_type = get_type_name(obj, "argType", allocator),
		mode     = convert_func_param_mode(obj, "mode"),
		defexpr  = get_node(obj, "defexpr", allocator),
	}
}

build_drop_function_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Drop_Function_Stmt {
	return Drop_Function_Stmt{
		objects    = get_node_list(obj, "objects", allocator),
		behavior   = convert_drop_behavior(obj, "behavior"),
		missing_ok = get_bool(obj, "missingOk"),
	}
}

build_create_schema_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Create_Schema_Stmt {
	return Create_Schema_Stmt{
		schemaname    = get_str(obj, "schemaname"),
		authrole      = get_node(obj, "authrole", allocator),
		schema_elts   = get_node_list(obj, "schemaElts", allocator),
		if_not_exists = get_bool(obj, "ifNotExists"),
	}
}

build_create_view_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Create_View_Stmt {
	return Create_View_Stmt{
		view              = get_range_var(obj, "view", allocator),
		aliases           = get_node_list(obj, "aliases", allocator),
		query             = get_node(obj, "query", allocator),
		replace           = get_bool(obj, "replace"),
		options           = get_node_list(obj, "options", allocator),
		with_check_option = get_i32(obj, "withCheckOption"),
	}
}

build_create_table_as_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Create_Table_As_Stmt {
	return Create_Table_As_Stmt{
		query          = get_node(obj, "query", allocator),
		into           = get_into_clause(obj, "into", allocator),
		objtype        = convert_object_type(obj, "objtype"),
		is_select_into = get_bool(obj, "isSelectInto"),
		if_not_exists  = get_bool(obj, "ifNotExists"),
	}
}

build_rename_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Rename_Stmt {
	return Rename_Stmt{
		rename_type   = convert_object_type(obj, "renameType"),
		relation_type = convert_object_type(obj, "relationType"),
		relation      = get_range_var(obj, "relation", allocator),
		object        = get_node(obj, "object", allocator),
		subname       = get_str(obj, "subname"),
		newname       = get_str(obj, "newname"),
		behavior      = convert_drop_behavior(obj, "behavior"),
		missing_ok    = get_bool(obj, "missingOk"),
	}
}

build_comment_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Comment_Stmt {
	return Comment_Stmt{
		objtype = convert_object_type(obj, "objtype"),
		object  = get_node(obj, "object", allocator),
		comment = get_str(obj, "comment"),
	}
}

build_alter_object_schema_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Alter_Object_Schema_Stmt {
	return Alter_Object_Schema_Stmt{
		object_type = convert_object_type(obj, "objectType"),
		relation    = get_range_var(obj, "relation", allocator),
		object      = get_node(obj, "object", allocator),
		newschema   = get_str(obj, "newschema"),
		missing_ok  = get_bool(obj, "missingOk"),
	}
}

build_create_extension_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Create_Extension_Stmt {
	return Create_Extension_Stmt{
		extname       = get_str(obj, "extname"),
		if_not_exists = get_bool(obj, "ifNotExists"),
		options       = get_node_list(obj, "options", allocator),
	}
}

build_composite_type_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Composite_Type_Stmt {
	return Composite_Type_Stmt{
		typevar    = get_range_var(obj, "typevar", allocator),
		coldeflist = get_node_list(obj, "coldeflist", allocator),
	}
}

build_index_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Index_Stmt {
	return Index_Stmt{
		idxname                = get_str(obj, "idxname"),
		relation               = get_range_var(obj, "relation", allocator),
		access_method          = get_str(obj, "accessMethod"),
		table_space            = get_str(obj, "tableSpace"),
		index_params           = get_node_list(obj, "indexParams", allocator),
		index_including_params = get_node_list(obj, "indexIncludingParams", allocator),
		options                = get_node_list(obj, "options", allocator),
		where_clause           = get_node(obj, "whereClause", allocator),
		exclude_op_names       = get_node_list(obj, "excludeOpNames", allocator),
		idxcomment             = get_str(obj, "idxcomment"),
		unique                 = get_bool(obj, "unique"),
		nulls_not_distinct     = get_bool(obj, "nullsNotDistinct"),
		primary                = get_bool(obj, "primary"),
		isconstraint           = get_bool(obj, "isconstraint"),
		deferrable             = get_bool(obj, "deferrable"),
		initdeferred           = get_bool(obj, "initdeferred"),
		concurrent             = get_bool(obj, "concurrent"),
		if_not_exists          = get_bool(obj, "ifNotExists"),
	}
}

build_create_seq_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Create_Seq_Stmt {
	return Create_Seq_Stmt{
		sequence      = get_range_var(obj, "sequence", allocator),
		options       = get_node_list(obj, "options", allocator),
		if_not_exists = get_bool(obj, "ifNotExists"),
	}
}

build_alter_seq_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Alter_Seq_Stmt {
	return Alter_Seq_Stmt{
		sequence   = get_range_var(obj, "sequence", allocator),
		options    = get_node_list(obj, "options", allocator),
		missing_ok = get_bool(obj, "missingOk"),
	}
}

build_grant_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Grant_Stmt {
	targtype: Grant_Target_Type
	switch get_enum_str(obj, "targtype") {
	case "ACL_TARGET_ALL_IN_SCHEMA": targtype = .All_In_Schema
	case "ACL_TARGET_DEFAULTS":      targtype = .Defaults
	case:                            targtype = .Object
	}
	return Grant_Stmt{
		is_grant     = get_bool(obj, "isGrant"),
		targtype     = targtype,
		objtype      = convert_object_type(obj, "objtype"),
		objects      = get_node_list(obj, "objects", allocator),
		privileges   = get_node_list(obj, "privileges", allocator),
		grantees     = get_node_list(obj, "grantees", allocator),
		grant_option = get_bool(obj, "grantOption"),
		grantor      = get_node(obj, "grantor", allocator),
		behavior     = convert_drop_behavior(obj, "behavior"),
	}
}

build_def_elem :: proc(obj: json.Object, allocator: mem.Allocator) -> Def_Elem {
	return Def_Elem{
		defnamespace = get_str(obj, "defnamespace"),
		defname      = get_str(obj, "defname"),
		arg          = get_node(obj, "arg", allocator),
		defaction    = convert_def_elem_action(obj, "defaction"),
		location     = get_i32(obj, "location"),
	}
}

build_role_spec :: proc(obj: json.Object) -> Role_Spec {
	return Role_Spec{
		roletype = get_i32(obj, "roletype"),
		rolename = get_str(obj, "rolename"),
		location = get_i32(obj, "location"),
	}
}

build_transaction_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Transaction_Stmt {
	return Transaction_Stmt{
		kind           = get_i32(obj, "kind"),
		options        = get_node_list(obj, "options", allocator),
		savepoint_name = get_str(obj, "savepointName"),
		gid            = get_str(obj, "gid"),
		chain          = get_bool(obj, "chain"),
		location       = get_i32(obj, "location"),
	}
}

build_do_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Do_Stmt {
	return Do_Stmt{
		args = get_node_list(obj, "args", allocator),
	}
}

build_prepare_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Prepare_Stmt {
	return Prepare_Stmt{
		name     = get_str(obj, "name"),
		argtypes = get_node_list(obj, "argtypes", allocator),
		query    = get_node(obj, "query", allocator),
	}
}

build_execute_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Execute_Stmt {
	return Execute_Stmt{
		name   = get_str(obj, "name"),
		params = get_node_list(obj, "params", allocator),
	}
}

build_raw_stmt :: proc(obj: json.Object, allocator: mem.Allocator) -> Raw_Stmt {
	return Raw_Stmt{
		stmt     = get_node(obj, "stmt", allocator),
		location = get_i32(obj, "stmtLocation"),
		length   = get_i32(obj, "stmtLen"),
	}
}

// ────────────────────────────────────────────────────────────────
// Main Dispatch — convert_node
// ────────────────────────────────────────────────────────────────

// Convert a discriminated JSON node value to an AST Node.
// Input: {"SelectStmt": {...}} or {"A_Const": {...}} etc.
// Returns nil for unknown or nil input.
convert_node :: proc(val: json.Value, allocator := context.allocator) -> ^Node {
	obj, ok := val.(json.Object)
	if !ok { return nil }

	// Discriminated node: single key = type name, value = fields
	for key, inner in obj {
		inner_obj, iok := inner.(json.Object)
		if !iok { continue }

		switch key {
		// Scalars
		case "String":      return alloc_node(build_string_node(inner_obj), allocator)
		case "Integer":     return alloc_node(build_integer_node(inner_obj), allocator)
		case "Float":       return alloc_node(build_float_node(inner_obj), allocator)
		case "Boolean":     return alloc_node(build_boolean_node(inner_obj), allocator)
		case "A_Star":      return alloc_node(build_a_star(inner_obj), allocator)
		case "A_Const":     return alloc_node(build_a_const(inner_obj, allocator), allocator)
		case "ParamRef":    return alloc_node(build_param_ref(inner_obj), allocator)

		// Expressions
		case "A_Expr":              return alloc_node(build_a_expr(inner_obj, allocator), allocator)
		case "BoolExpr":            return alloc_node(build_bool_expr(inner_obj, allocator), allocator)
		case "FuncCall":            return alloc_node(build_func_call(inner_obj, allocator), allocator)
		case "TypeCast":            return alloc_node(build_type_cast(inner_obj, allocator), allocator)
		case "CaseExpr":            return alloc_node(build_case_expr(inner_obj, allocator), allocator)
		case "CaseWhen":            return alloc_node(build_case_when(inner_obj, allocator), allocator)
		case "SubLink":             return alloc_node(build_sub_link(inner_obj, allocator), allocator)
		case "CoalesceExpr":        return alloc_node(build_coalesce_expr(inner_obj, allocator), allocator)
		case "NullTest":            return alloc_node(build_null_test(inner_obj, allocator), allocator)
		case "BooleanTest":         return alloc_node(build_boolean_test(inner_obj, allocator), allocator)
		case "RowExpr":             return alloc_node(build_row_expr(inner_obj, allocator), allocator)
		case "A_ArrayExpr":         return alloc_node(build_a_array_expr(inner_obj, allocator), allocator)
		case "A_Indices":           return alloc_node(build_a_indices(inner_obj, allocator), allocator)
		case "A_Indirection":       return alloc_node(build_a_indirection(inner_obj, allocator), allocator)
		case "MinMaxExpr":          return alloc_node(build_min_max_expr(inner_obj, allocator), allocator)
		case "XmlExpr":             return alloc_node(build_xml_expr(inner_obj, allocator), allocator)
		case "SQLValueFunction":    return alloc_node(build_sql_value_function(inner_obj), allocator)
		case "SetToDefault":        return alloc_node(build_set_to_default(inner_obj), allocator)
		case "ParenExpr":           return alloc_node(build_paren_expr(inner_obj, allocator), allocator)

		// References
		case "ColumnRef":       return alloc_node(build_column_ref(inner_obj, allocator), allocator)
		case "RangeVar":        return alloc_node(build_range_var(inner_obj, allocator), allocator)
		case "RangeSubselect":  return alloc_node(build_range_subselect(inner_obj, allocator), allocator)
		case "RangeFunction":   return alloc_node(build_range_function(inner_obj, allocator), allocator)
		case "JoinExpr":        return alloc_node(build_join_expr(inner_obj, allocator), allocator)
		case "ResTarget":       return alloc_node(build_res_target(inner_obj, allocator), allocator)

		// Types / Names / Definitions
		case "TypeName":
			tn := build_type_name(inner_obj, allocator)
			fill_type_name_from_names(&tn, inner_obj, allocator)
			return alloc_node(tn, allocator)
		case "ColumnDef":       return alloc_node(build_column_def(inner_obj, allocator), allocator)
		case "Constraint":      return alloc_node(build_constraint(inner_obj, allocator), allocator)
		case "Alias":           return alloc_node(build_alias(inner_obj, allocator), allocator)
		case "SortBy":          return alloc_node(build_sort_by(inner_obj, allocator), allocator)
		case "WindowDef":       return alloc_node(build_window_def(inner_obj, allocator), allocator)
		case "LockingClause":   return alloc_node(build_locking_clause(inner_obj, allocator), allocator)
		case "IntoClause":      return alloc_node(build_into_clause(inner_obj, allocator), allocator)
		case "OnConflictClause": return alloc_node(build_on_conflict_clause(inner_obj, allocator), allocator)
		case "InferClause":     return alloc_node(build_infer_clause(inner_obj, allocator), allocator)
		case "IndexElem":       return alloc_node(build_index_elem(inner_obj, allocator), allocator)
		case "MultiAssignRef":  return alloc_node(build_multi_assign_ref(inner_obj, allocator), allocator)
		case "GroupingSet":     return alloc_node(build_grouping_set(inner_obj, allocator), allocator)

		// Containers
		case "List":            return alloc_node(build_list(inner_obj, allocator), allocator)
		case "RawStmt":         return alloc_node(build_raw_stmt(inner_obj, allocator), allocator)
		case "WithClause":      return alloc_node(build_with_clause(inner_obj, allocator), allocator)
		case "CommonTableExpr": return alloc_node(build_common_table_expr(inner_obj, allocator), allocator)

		// DML Statements
		case "SelectStmt":    return alloc_node(build_select_stmt(inner_obj, allocator), allocator)
		case "InsertStmt":    return alloc_node(build_insert_stmt(inner_obj, allocator), allocator)
		case "UpdateStmt":    return alloc_node(build_update_stmt(inner_obj, allocator), allocator)
		case "DeleteStmt":    return alloc_node(build_delete_stmt(inner_obj, allocator), allocator)
		case "TruncateStmt":  return alloc_node(build_truncate_stmt(inner_obj, allocator), allocator)
		case "ExplainStmt":   return alloc_node(build_explain_stmt(inner_obj, allocator), allocator)
		case "CopyStmt":      return alloc_node(build_copy_stmt(inner_obj, allocator), allocator)

		// DDL Statements
		case "CreateStmt":              return alloc_node(build_create_table_stmt(inner_obj, allocator), allocator)
		case "CreateTableAsStmt":       return alloc_node(build_create_table_as_stmt(inner_obj, allocator), allocator)
		case "AlterTableStmt":          return alloc_node(build_alter_table_stmt(inner_obj, allocator), allocator)
		case "AlterTableCmd":           return alloc_node(build_alter_table_cmd(inner_obj, allocator), allocator)
		case "DropStmt":                return alloc_node(build_drop_stmt(inner_obj, allocator), allocator)
		case "CreateEnumStmt":          return alloc_node(build_create_enum_stmt(inner_obj, allocator), allocator)
		case "AlterEnumStmt":           return alloc_node(build_alter_enum_stmt(inner_obj, allocator), allocator)
		case "CreateFunctionStmt":      return alloc_node(build_create_function_stmt(inner_obj, allocator), allocator)
		case "FunctionParameter":       return alloc_node(build_function_parameter(inner_obj, allocator), allocator)
		case "DropFunctionStmt":        return alloc_node(build_drop_function_stmt(inner_obj, allocator), allocator)
		case "CreateSchemaStmt":        return alloc_node(build_create_schema_stmt(inner_obj, allocator), allocator)
		case "ViewStmt":                return alloc_node(build_create_view_stmt(inner_obj, allocator), allocator)
		case "RenameStmt":              return alloc_node(build_rename_stmt(inner_obj, allocator), allocator)
		case "CommentStmt":             return alloc_node(build_comment_stmt(inner_obj, allocator), allocator)
		case "AlterObjectSchemaStmt":   return alloc_node(build_alter_object_schema_stmt(inner_obj, allocator), allocator)
		case "CreateExtensionStmt":     return alloc_node(build_create_extension_stmt(inner_obj, allocator), allocator)
		case "CompositeTypeStmt":       return alloc_node(build_composite_type_stmt(inner_obj, allocator), allocator)
		case "IndexStmt":               return alloc_node(build_index_stmt(inner_obj, allocator), allocator)
		case "CreateSeqStmt":           return alloc_node(build_create_seq_stmt(inner_obj, allocator), allocator)
		case "AlterSeqStmt":            return alloc_node(build_alter_seq_stmt(inner_obj, allocator), allocator)
		case "GrantStmt":               return alloc_node(build_grant_stmt(inner_obj, allocator), allocator)
		case "DefElem":                 return alloc_node(build_def_elem(inner_obj, allocator), allocator)
		case "RoleSpec":                return alloc_node(build_role_spec(inner_obj), allocator)
		case "TransactionStmt":         return alloc_node(build_transaction_stmt(inner_obj, allocator), allocator)
		case "DoStmt":                  return alloc_node(build_do_stmt(inner_obj, allocator), allocator)
		case "PrepareStmt":             return alloc_node(build_prepare_stmt(inner_obj, allocator), allocator)
		case "ExecuteStmt":             return alloc_node(build_execute_stmt(inner_obj, allocator), allocator)
		}
		break  // only process the first key
	}
	return nil
}
