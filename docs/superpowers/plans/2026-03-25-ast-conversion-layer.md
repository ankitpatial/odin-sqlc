# AST Conversion Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the JSON→AST conversion pipeline, AST traversal, and SQL formatting — turning raw libpg_query JSON output into typed Odin AST nodes that can be walked and printed.

**Architecture:** Five files in two packages. `ast/convert.odin` dispatches on JSON type keys to produce AST nodes. `ast/translate.odin` intercepts DDL statements for semantic enrichment (primary keys, NOT NULL, etc.) before falling through to the generic converter. `ast/walk.odin` provides depth-first traversal via `#partial switch`. `ast/format.odin` reconstructs SQL strings from AST nodes. `source/source.odin` provides text manipulation utilities. All JSON field names come from libpg_query's protobuf `json_name` annotations (mostly camelCase).

**Tech Stack:** Odin (dev-2026-03), core:encoding/json, libpg_query v17 JSON output

**Spec:** `docs/superpowers/specs/2026-03-24-odin-sqlc-design.md`

**Depends on:** Foundation Layer (complete) — `pg/`, `ast/` types, `pg_query/` bindings

---

## Critical JSON Format Notes

libpg_query v17 returns JSON with these conventions (verified against actual output):

1. **Node wrappers:** Every `Node`-typed field uses a discriminated object: `{"SelectStmt": {...fields...}}`
2. **Typed fields:** Specific-type fields (like `relation: RangeVar`) appear WITHOUT discriminator: `{"relname": "users", ...}`
3. **Field naming:** protobuf `json_name` — mostly camelCase for multi-word fields (`targetList`, `fromClause`), some keep underscores (`is_local`, `is_not_null`)
4. **Enum values:** String constants like `"SETOP_NONE"`, `"AEXPR_OP"`, `"CONSTR_PRIMARY"`
5. **A_Const:** Uses protobuf oneof — value type determined by which field is present (`ival`, `sval`, `fval`, `boolval`, `bsval`, or `isnull`)
6. **Missing fields = default values:** proto3 omits defaults (0, false, empty string, first enum)
7. **Boolean default caveat:** `RangeVar.inh` defaults to `true` in PostgreSQL but proto3 omits `true`. Use `get_bool_default(obj, "inh", true)` for this field.

---

## File Structure

### source/ package (new)
- Create: `source/source.odin` — pluck, mutate, strip_comments, line_number
- Create: `source/tests/source_test.odin` — tests

### ast/ package (extending existing)
- Modify: `ast/enums.odin` — extend enums to match protobuf values
- Create: `ast/convert.odin` — JSON→AST conversion dispatch + all converters
- Create: `ast/translate.odin` — DDL-specific semantic translation
- Create: `ast/walk.odin` — AST traversal (walk, search, apply)
- Create: `ast/format.odin` — AST→SQL formatting
- Create: `ast/tests/convert_test.odin` — integration tests for conversion
- Create: `ast/tests/walk_test.odin` — walk/search/apply tests
- Create: `ast/tests/format_test.odin` — formatting tests

---

## Task 1: Extend ast/enums.odin for Protobuf Compatibility

**Files:**
- Modify: `ast/enums.odin`

The foundation layer defined simplified enums. The conversion layer needs the full set of protobuf enum values to correctly parse JSON strings like `"AEXPR_OP"`, `"CONSTR_PRIMARY"`, etc.

- [ ] **Step 1: Extend A_Expr_Kind with missing protobuf variants**

Add after `Not_In`:
```odin
A_Expr_Kind :: enum {
	Undefined,
	Op,        // AEXPR_OP: normal operator
	Op_Any,    // AEXPR_OP_ANY: scalar op ANY (array)
	Op_All,    // AEXPR_OP_ALL: scalar op ALL (array)
	Distinct,  // AEXPR_DISTINCT: IS DISTINCT FROM
	Not_Distinct, // AEXPR_NOT_DISTINCT: IS NOT DISTINCT FROM
	Nullif,    // AEXPR_NULLIF: NULLIF(a, b)
	In,        // AEXPR_IN: IN
	Like,      // AEXPR_LIKE: LIKE
	ILike,     // AEXPR_ILIKE: ILIKE
	Similar,   // AEXPR_SIMILAR: SIMILAR TO
	Between,   // AEXPR_BETWEEN: BETWEEN
	Not_Between, // AEXPR_NOT_BETWEEN: NOT BETWEEN
	Between_Sym, // AEXPR_BETWEEN_SYM: BETWEEN SYMMETRIC
	Not_Between_Sym, // AEXPR_NOT_BETWEEN_SYM: NOT BETWEEN SYMMETRIC
}
```

- [ ] **Step 2: Add Sub_Link_Type CTE variant**

```odin
Sub_Link_Type :: enum {
	Exists,
	All,
	Any,
	Row_Compare,
	Expr,
	Multiexpr,
	Array,
	CTE,
}
```

- [ ] **Step 3: Add On_Commit_Action enum**

Add new enum after `Grouping_Set_Kind`:
```odin
// On commit behavior for temp tables
On_Commit_Action :: enum {
	Noop,
	Preserve_Rows,
	Delete_Rows,
	Drop,
}

// Overriding kind for INSERT
Overriding_Kind :: enum {
	Not_Set,
	User_Value,
	System_Value,
}

// Boolean test type
Bool_Test_Type :: enum {
	Is_True,
	Is_Not_True,
	Is_False,
	Is_Not_False,
	Is_Unknown,
	Is_Not_Unknown,
}

// Coercion form
Coercion_Form :: enum {
	Explicit_Call,
	Explicit_Cast,
	Implicit_Cast,
	SQL_Value_Function,
}

// CTE materialization
CTE_Materialize :: enum {
	Default,
	Always,
	Never,
}
```

- [ ] **Step 4: Verify it compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 5: Run existing tests**

Run: `odin test ast/tests/`
Expected: All 8 tests pass (no regressions)

- [ ] **Step 6: Commit**

```bash
git add ast/enums.odin
git commit -m "feat(ast): extend enums for protobuf JSON compatibility"
```

---

## Task 2: source/source.odin — Source Text Manipulation

**Files:**
- Create: `source/source.odin`
- Create: `source/tests/source_test.odin`

Direct port of Go's `internal/source/code.go` (166 lines). No external dependencies.

- [ ] **Step 1: Write the source test file**

```odin
package source_tests

import "core:testing"
import source "../"

@(test)
test_pluck_basic :: proc(t: ^testing.T) {
	sql := "SELECT 1; SELECT 2"
	result := source.pluck(sql, 0, 8)
	testing.expect_value(t, result, "SELECT 1")
}

@(test)
test_pluck_second_stmt :: proc(t: ^testing.T) {
	sql := "SELECT 1; SELECT 2"
	result := source.pluck(sql, 10, 8)
	testing.expect_value(t, result, "SELECT 2")
}

@(test)
test_pluck_zero_length :: proc(t: ^testing.T) {
	sql := "SELECT 1; SELECT 2"
	result := source.pluck(sql, 10, 0)
	testing.expect_value(t, result, "SELECT 2")
}

@(test)
test_mutate_single_edit :: proc(t: ^testing.T) {
	sql := "SELECT * FROM users"
	edits := []source.Edit{
		{location = 7, old_len = 1, new_text = "id, name"},
	}
	result := source.mutate(sql, edits)
	testing.expect_value(t, result, "SELECT id, name FROM users")
}

@(test)
test_mutate_multiple_edits :: proc(t: ^testing.T) {
	sql := "SELECT * FROM users WHERE id = $1"
	edits := []source.Edit{
		{location = 7, old_len = 1, new_text = "id, name"},
		{location = 31, old_len = 2, new_text = "$2"},
	}
	result := source.mutate(sql, edits)
	testing.expect_value(t, result, "SELECT id, name FROM users WHERE id = $2")
}

@(test)
test_mutate_empty_edits :: proc(t: ^testing.T) {
	sql := "SELECT 1"
	result := source.mutate(sql, {})
	testing.expect_value(t, result, "SELECT 1")
}

@(test)
test_strip_comments_line_comment :: proc(t: ^testing.T) {
	sql := "-- name: GetUser :one\nSELECT * FROM users"
	result := source.strip_comments(sql)
	// Should strip the comment line
	testing.expect(t, len(result) > 0, "expected non-empty result")
}

@(test)
test_line_number :: proc(t: ^testing.T) {
	sql := "SELECT 1;\nSELECT 2;\nSELECT 3;"
	line := source.line_number(sql, 10)
	testing.expect_value(t, line, i32(2))
}

@(test)
test_line_number_first_line :: proc(t: ^testing.T) {
	sql := "SELECT 1"
	line := source.line_number(sql, 0)
	testing.expect_value(t, line, i32(1))
}
```

- [ ] **Step 2: Verify tests fail (no implementation yet)**

Run: `odin test source/tests/`
Expected: Compilation error — source package doesn't exist yet

- [ ] **Step 3: Write source/source.odin**

```odin
package source

import "core:strings"
import "core:slice"

// An edit to the source text (position + replacement)
Edit :: struct {
	location: i32,  // byte offset in original source
	old_len:  i32,  // bytes to replace
	new_text: string, // replacement text
}

// Extract the SQL text for a specific statement from a multi-statement file.
// If length is 0, returns from location to end of source.
pluck :: proc(src: string, location: i32, length: i32) -> string {
	loc := int(location)
	if loc >= len(src) {
		return ""
	}
	if length == 0 {
		return src[loc:]
	}
	end := loc + int(length)
	if end > len(src) {
		end = len(src)
	}
	return src[loc:end]
}

// Apply accumulated edits to source text.
// Edits are applied in reverse order of location to preserve offsets.
mutate :: proc(src: string, edits: []Edit, allocator := context.allocator) -> string {
	if len(edits) == 0 {
		return strings.clone(src, allocator)
	}

	// Sort edits by location descending (apply from end to start)
	sorted := make([]Edit, len(edits), context.temp_allocator)
	copy(sorted, edits)
	slice.sort_by(sorted, proc(a, b: Edit) -> bool {
		return a.location > b.location
	})

	result := strings.clone(src, context.temp_allocator)
	for edit in sorted {
		loc := int(edit.location)
		end := loc + int(edit.old_len)
		if loc > len(result) { continue }
		if end > len(result) { end = len(result) }

		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, result[:loc])
		strings.write_string(&b, edit.new_text)
		strings.write_string(&b, result[end:])
		result = strings.to_string(b)
	}

	return strings.clone(result, allocator)
}

// Remove SQL comments from query text.
// Handles -- line comments and /* block comments */.
strip_comments :: proc(src: string, allocator := context.allocator) -> string {
	buf := strings.builder_make(allocator)
	i := 0
	for i < len(src) {
		// Line comment
		if i + 1 < len(src) && src[i] == '-' && src[i + 1] == '-' {
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			continue
		}
		// Block comment
		if i + 1 < len(src) && src[i] == '/' && src[i + 1] == '*' {
			i += 2
			for i + 1 < len(src) {
				if src[i] == '*' && src[i + 1] == '/' {
					i += 2
					break
				}
				i += 1
			}
			continue
		}
		strings.write_byte(&buf, src[i])
		i += 1
	}
	return strings.to_string(buf)
}

// Get line number from byte offset (1-based).
line_number :: proc(src: string, offset: i32) -> i32 {
	off := int(offset)
	if off > len(src) {
		off = len(src)
	}
	line: i32 = 1
	for i := 0; i < off; i += 1 {
		if src[i] == '\n' {
			line += 1
		}
	}
	return line
}
```

- [ ] **Step 4: Run the tests**

Run: `odin test source/tests/`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add source/source.odin source/tests/source_test.odin
git commit -m "feat(source): add source text manipulation utilities"
```

---

## Task 3: ast/convert.odin Part 1 — JSON Helpers and Core Infrastructure

**Files:**
- Create: `ast/convert.odin`

This is the beginning of the large conversion file. This task establishes the JSON extraction helpers, the main `convert_node` dispatch skeleton, enum conversion functions, allocation helpers, and scalar/leaf node converters.

- [ ] **Step 1: Write the JSON helper functions and enum converters**

Create `ast/convert.odin` with:

```odin
package ast

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:strconv"

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
```

- [ ] **Step 2: Verify it compiles (partial — missing forward declarations)**

Run: `odin check ast/ -vet -no-entry-point`
Expected: May have errors for forward references to build_* procs and convert_node. If so, add forward declarations or stub procs. The file compiles as a whole once all parts are added.

Note: Steps 3-5 (Tasks 3-5) all build up this same file. Test compilation after all converters are in place.

- [ ] **Step 3: Commit work-in-progress**

```bash
git add ast/convert.odin
git commit -m "feat(ast): add JSON helpers and enum converters for AST conversion"
```

---

## Task 4: ast/convert.odin Part 2 — Scalar, Expression, and Reference Converters

**Files:**
- Modify: `ast/convert.odin` (append to existing)

- [ ] **Step 1: Add scalar/leaf node converters**

Append to `ast/convert.odin`:

```odin
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
	if ival_obj, ok := get_obj(obj, "ival"); ok {
		c.type = .Integer
		c.ival = get_i64(ival_obj, "ival")
	} else if sval_obj, ok := get_obj(obj, "sval"); ok {
		c.type = .String
		c.sval = get_str(sval_obj, "sval")
	} else if fval_obj, ok := get_obj(obj, "fval"); ok {
		c.type = .Float
		c.fval = get_str(fval_obj, "fval")
	} else if bval_obj, ok := get_obj(obj, "boolval"); ok {
		c.type = .Boolean
		c.bval = get_bool(bval_obj, "boolval")
	} else if bs_obj, ok := get_obj(obj, "bsval"); ok {
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
		funcname       = get_node_list(obj, "funcname", allocator),
		args           = get_node_list(obj, "args", allocator),
		agg_order      = get_node_list(obj, "aggOrder", allocator),
		agg_filter     = get_node(obj, "aggFilter", allocator),
		over           = get_window_def(obj, "over", allocator),
		agg_within_group = get_bool(obj, "aggWithinGroup"),
		agg_star       = get_bool(obj, "aggStar"),
		agg_distinct   = get_bool(obj, "aggDistinct"),
		func_variadic  = get_bool(obj, "funcVariadic"),
		funcformat     = get_i32(obj, "funcformat"),
		location       = get_i32(obj, "location"),
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
		// TypeName.names is "names" in JSON, but our struct field is different
		// names → array_bounds, etc. need to map JSON fields to our struct fields
		// JSON: names, typeOid, setof, pctType, typmods, typemod, arrayBounds, location
		// Our struct: catalog, schema, name, array_bounds, set_of, pct_type, typmods, location
		//
		// Note: libpg_query TypeName has "names" (list of String nodes like ["pg_catalog","int4"])
		// which we need to parse into catalog/schema/name fields.
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
		ctename        = get_str(obj, "ctename"),
		aliascolnames  = get_node_list(obj, "aliascolnames", allocator),
		ctematerialized = get_i32(obj, "ctematerialized"),
		ctequery       = get_node(obj, "ctequery", allocator),
		location       = get_i32(obj, "location"),
		cterecursive   = get_bool(obj, "cterecursive"),
		cterefcount    = get_i32(obj, "cterefcount"),
		ctecolnames    = get_node_list(obj, "ctecolnames", allocator),
		ctecoltypes    = get_node_list(obj, "ctecoltypes", allocator),
		ctecoltypmods  = get_node_list(obj, "ctecoltypmods", allocator),
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
		contype             = convert_constraint_type(obj, "contype"),
		conname             = get_str(obj, "conname"),
		deferrable          = get_bool(obj, "deferrable"),
		initdeferred        = get_bool(obj, "initdeferred"),
		location            = get_i32(obj, "location"),
		is_no_inherit       = get_bool(obj, "isNoInherit"),
		raw_expr            = get_node(obj, "rawExpr", allocator),
		cooked_expr         = get_str(obj, "cookedExpr"),
		generated_when      = get_byte(obj, "generatedWhen"),
		keys                = get_node_list(obj, "keys", allocator),
		including           = get_node_list(obj, "including", allocator),
		exclusions          = get_node_list(obj, "exclusions", allocator),
		options             = get_node_list(obj, "options", allocator),
		indexname            = get_str(obj, "indexname"),
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
```

- [ ] **Step 2: Commit**

```bash
git add ast/convert.odin
git commit -m "feat(ast): add scalar, expression, and reference converters"
```

---

## Task 5: ast/convert.odin Part 3 — Statement Converters and Dispatch

**Files:**
- Modify: `ast/convert.odin` (append)
- Create: `ast/tests/convert_test.odin`

- [ ] **Step 1: Add DML statement converters**

Append to `ast/convert.odin`:

```odin
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
		// values_lists handled specially — see below
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
		lateral    = get_bool(obj, "lateral"),
		ordinality = get_bool(obj, "ordinality"),
		is_rowsfrom = get_bool(obj, "isRowsfrom"),
		functions  = get_node_list(obj, "functions", allocator),
		alias      = get_alias(obj, "alias", allocator),
		coldeflist = get_node_list(obj, "coldeflist", allocator),
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
```

- [ ] **Step 2: Fix values_lists in build_select_stmt**

Update build_select_stmt to call convert_values_lists:

After the `build_select_stmt` proc, add the values_lists conversion. The values_lists field needs to be set after initial construction:

Actually, modify build_select_stmt to include:
```odin
// In build_select_stmt, replace the values_lists line:
values_lists    = convert_values_lists(obj, allocator),
```

- [ ] **Step 3: Fix TypeName build to include name extraction**

The `get_type_name` helper builds a Type_Name but doesn't extract the catalog/schema/name from the `names` list. Update it:

```odin
get_type_name :: proc(obj: json.Object, key: string, allocator: mem.Allocator) -> ^Type_Name {
	inner, ok := get_obj(obj, key)
	if !ok { return nil }
	tn := new(Type_Name, allocator)
	tn^ = build_type_name(inner, allocator)
	fill_type_name_from_names(tn, inner, allocator)
	return tn
}
```

- [ ] **Step 4: Verify ast/ compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 5: Write integration tests**

Create `ast/tests/convert_test.odin`:

```odin
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
```

- [ ] **Step 6: Run all tests**

Run: `odin test ast/tests/`
Expected: All tests pass (both new convert tests and existing node tests)

- [ ] **Step 7: Commit**

```bash
git add ast/convert.odin ast/tests/convert_test.odin
git commit -m "feat(ast): add JSON-to-AST conversion with full dispatch"
```

---

## Task 6: ast/translate.odin — DDL Semantic Translation

**Files:**
- Create: `ast/translate.odin`

Mirrors Go's `translate()` in `parse.go`. Intercepts ~12 DDL statement types for semantic enrichment, delegates everything else to `convert_node`.

- [ ] **Step 1: Write ast/translate.odin**

```odin
package ast

import "core:encoding/json"
import "core:mem"

// ────────────────────────────────────────────────────────────────
// Relation Parsing Helpers
// ────────────────────────────────────────────────────────────────

// Parse a list of String nodes into a Table_Name.
parse_relation_from_nodes :: proc(nodes: [dynamic]^Node) -> Table_Name {
	parts := make([dynamic]string, 0, 3, context.temp_allocator)
	for n in nodes {
		if n == nil { continue }
		if s, ok := n^.(String_Node); ok {
			append(&parts, s.sval)
		}
	}
	tn := Table_Name{}
	switch len(parts) {
	case 1: tn.name = parts[0]
	case 2: tn.schema = parts[0]; tn.name = parts[1]
	case 3: tn.catalog = parts[0]; tn.schema = parts[1]; tn.name = parts[2]
	}
	return tn
}

// Parse a RangeVar into a Table_Name.
parse_relation_from_range_var :: proc(rv: ^Range_Var) -> Table_Name {
	if rv == nil { return {} }
	return Table_Name{
		catalog = rv.catalogname,
		schema  = rv.schemaname,
		name    = rv.relname,
	}
}

// Check if a ColumnDef is NOT NULL (via flag or constraints).
is_column_not_null :: proc(cd: Column_Def) -> bool {
	if cd.is_not_null { return true }
	for c in cd.constraints {
		if c == nil { continue }
		if con, ok := c^.(Constraint); ok {
			if con.contype == .Not_Null || con.contype == .Primary_Key {
				return true
			}
		}
	}
	return false
}

// Check if a TypeName has array bounds.
is_type_array :: proc(tn: ^Type_Name) -> bool {
	if tn == nil { return false }
	return len(tn.array_bounds) > 0
}

// ────────────────────────────────────────────────────────────────
// Public API: translate
//
// Top-level entry point for converting parsed JSON into AST nodes.
// Handles DDL statements with semantic enrichment; delegates
// everything else to convert_node.
// ────────────────────────────────────────────────────────────────

translate :: proc(stmt_json: json.Value, allocator := context.allocator) -> ^Node {
	obj, ok := stmt_json.(json.Object)
	if !ok { return nil }

	for key, inner in obj {
		inner_obj, iok := inner.(json.Object)
		if !iok { continue }

		switch key {
		case "CreateStmt":
			return translate_create_table(inner_obj, allocator)
		case "AlterTableStmt":
			return translate_alter_table(inner_obj, allocator)
		case "AlterEnumStmt":
			return translate_alter_enum(inner_obj, allocator)
		case "CommentStmt":
			return translate_comment(inner_obj, allocator)
		case "RenameStmt":
			return translate_rename(inner_obj, allocator)
		case "DropStmt":
			return translate_drop(inner_obj, allocator)
		case:
			// Non-DDL or unhandled DDL → generic converter
			return convert_node(stmt_json, allocator)
		}
		break
	}
	return nil
}

// ────────────────────────────────────────────────────────────────
// DDL Translators
// ────────────────────────────────────────────────────────────────

translate_create_table :: proc(obj: json.Object, allocator: mem.Allocator) -> ^Node {
	rel := get_range_var(obj, "relation", allocator)

	// Build primary key set from table-level constraints
	primary_keys := make(map[string]bool, 8, context.temp_allocator)
	elts := get_node_list(obj, "tableElts", allocator)
	for e in elts {
		if e == nil { continue }
		if con, ok := e^.(Constraint); ok {
			if con.contype == .Primary_Key {
				for k in con.keys {
					if k == nil { continue }
					if s, sok := k^.(String_Node); sok {
						primary_keys[s.sval] = true
					}
				}
			}
		}
	}

	// Process column definitions with semantic enrichment
	table_elts := make([dynamic]^Node, 0, len(elts), allocator)
	for e in elts {
		if e == nil { continue }
		if cd, ok := e^.(Column_Def); ok {
			// Mark as NOT NULL if in primary key set
			is_pk := cd.colname in primary_keys
			if is_pk {
				cd.is_not_null = true
			}
			// Also check constraint-based NOT NULL
			if !cd.is_not_null {
				cd.is_not_null = is_column_not_null(cd)
			}
			node := alloc_node(cd, allocator)
			append(&table_elts, node)
		} else {
			append(&table_elts, e)
		}
	}

	return alloc_node(Create_Table_Stmt{
		relation       = rel,
		table_elts     = table_elts,
		inh_relations  = get_node_list(obj, "inhRelations", allocator),
		constraints    = get_node_list(obj, "constraints", allocator),
		options        = get_node_list(obj, "options", allocator),
		oncommit       = get_i32(obj, "oncommit"),
		tablespacename = get_str(obj, "tablespacename"),
		access_method  = get_str(obj, "accessMethod"),
		if_not_exists  = get_bool(obj, "ifNotExists"),
	}, allocator)
}

translate_alter_table :: proc(obj: json.Object, allocator: mem.Allocator) -> ^Node {
	rel := get_range_var(obj, "relation", allocator)

	// Process commands with semantic enrichment
	raw_cmds := get_node_list(obj, "cmds", allocator)
	cmds := make([dynamic]^Node, 0, len(raw_cmds), allocator)
	for c in raw_cmds {
		if c == nil { continue }
		if cmd, ok := c^.(Alter_Table_Cmd); ok {
			// For Add_Column: ensure NOT NULL is detected from constraints
			if cmd.subtype == .Add_Column {
				if cmd.def != nil {
					if cd, cdok := cmd.def^.(Column_Def); cdok {
						cd.is_not_null = is_column_not_null(cd)
						cmd.def = alloc_node(cd, allocator)
					}
				}
			}
			append(&cmds, alloc_node(cmd, allocator))
		} else {
			append(&cmds, c)
		}
	}

	return alloc_node(Alter_Table_Stmt{
		relation   = rel,
		cmds       = cmds,
		objtype    = convert_object_type(obj, "objtype"),
		missing_ok = get_bool(obj, "missingOk"),
	}, allocator)
}

translate_alter_enum :: proc(obj: json.Object, allocator: mem.Allocator) -> ^Node {
	// Generic conversion is sufficient — no special semantic logic
	return alloc_node(build_alter_enum_stmt(obj, allocator), allocator)
}

translate_comment :: proc(obj: json.Object, allocator: mem.Allocator) -> ^Node {
	return alloc_node(build_comment_stmt(obj, allocator), allocator)
}

translate_rename :: proc(obj: json.Object, allocator: mem.Allocator) -> ^Node {
	return alloc_node(build_rename_stmt(obj, allocator), allocator)
}

translate_drop :: proc(obj: json.Object, allocator: mem.Allocator) -> ^Node {
	return alloc_node(build_drop_stmt(obj, allocator), allocator)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Add translate integration tests to convert_test.odin**

Append to `ast/tests/convert_test.odin`:

```odin
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

	// First column: id — should be NOT NULL (from PRIMARY KEY)
	cd0, cd0ok := ct.table_elts[0]^.(ast.Column_Def)
	testing.expect(t, cd0ok, "expected Column_Def")
	testing.expect_value(t, cd0.colname, "id")
	testing.expect(t, cd0.is_not_null, "id should be NOT NULL (primary key)")

	// Second column: name — explicit NOT NULL
	cd1, cd1ok := ct.table_elts[1]^.(ast.Column_Def)
	testing.expect(t, cd1ok, "expected Column_Def")
	testing.expect_value(t, cd1.colname, "name")
	testing.expect(t, cd1.is_not_null, "name should be NOT NULL")

	// Third column: email — nullable
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
```

- [ ] **Step 4: Run all tests**

Run: `odin test ast/tests/`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add ast/translate.odin ast/tests/convert_test.odin
git commit -m "feat(ast): add DDL semantic translation layer"
```

---

## Task 7: ast/walk.odin — AST Traversal

**Files:**
- Create: `ast/walk.odin`
- Create: `ast/tests/walk_test.odin`

Replaces Go's `walk.go` (2200 lines) + `rewrite.go` (1271 lines) + `search.go` (21 lines). Odin's `#partial switch` makes this much more compact since leaf nodes need no case.

- [ ] **Step 1: Write walk tests first**

Create `ast/tests/walk_test.odin`:

```odin
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
```

- [ ] **Step 2: Write ast/walk.odin**

```odin
package ast

// Visitor callback — return false to stop walking.
Visitor :: #type proc(node: ^Node, user_data: rawptr) -> bool

// Walk the AST depth-first, calling visitor for each node.
// If visitor returns false, walking stops.
walk :: proc(node: ^Node, visitor: Visitor, user_data: rawptr) {
	if node == nil { return }
	if !visitor(node, user_data) { return }
	walk_children(node, visitor, user_data)
}

// Search for the first node matching a predicate.
search :: proc(node: ^Node, pred: proc(^Node) -> bool) -> ^Node {
	if node == nil { return nil }
	if pred(node) { return node }

	Search_State :: struct {
		pred:   proc(^Node) -> bool,
		result: ^Node,
	}
	state := Search_State{pred = pred}

	walk_children(node, proc(n: ^Node, data: rawptr) -> bool {
		s := cast(^Search_State)data
		if s.result != nil { return false }
		if s.pred(n) {
			s.result = n
			return false
		}
		return true
	}, &state)

	return state.result
}

// Apply a transformation to every node (depth-first, post-order).
apply :: proc(node: ^Node, transform: proc(^Node) -> ^Node) {
	if node == nil { return }
	apply_children(node, transform)
	new_node := transform(node)
	if new_node != nil && new_node != node {
		node^ = new_node^
	}
}

// ── Internal: walk into all child nodes ───────────────────────

walk_children :: proc(node: ^Node, visitor: Visitor, user_data: rawptr) {
	if node == nil { return }

	#partial switch &n in node^ {
	// DML Statements
	case Select_Stmt:
		walk_list(n.distinct_clause, visitor, user_data)
		walk(n.into_clause, visitor, user_data)
		walk_list(n.target_list, visitor, user_data)
		walk_list(n.from_clause, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.group_clause, visitor, user_data)
		walk(n.having_clause, visitor, user_data)
		walk_list(n.window_clause, visitor, user_data)
		walk_list(n.sort_clause, visitor, user_data)
		walk(n.limit_offset, visitor, user_data)
		walk(n.limit_count, visitor, user_data)
		walk_list(n.locking_clause, visitor, user_data)
		// Typed pointer children — wrap in temp Node to walk
		if n.with_clause != nil {
			walk_list(n.with_clause.ctes, visitor, user_data)
		}
		if n.larg != nil {
			temp: Node = n.larg^
			walk(&temp, visitor, user_data)
		}
		if n.rarg != nil {
			temp: Node = n.rarg^
			walk(&temp, visitor, user_data)
		}

	case Insert_Stmt:
		walk_list(n.cols, visitor, user_data)
		walk(n.select_stmt, visitor, user_data)
		walk_list(n.returning_list, visitor, user_data)
		if n.with_clause != nil {
			walk_list(n.with_clause.ctes, visitor, user_data)
		}

	case Update_Stmt:
		walk_list(n.target_list, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.from_clause, visitor, user_data)
		walk_list(n.returning_list, visitor, user_data)
		if n.with_clause != nil {
			walk_list(n.with_clause.ctes, visitor, user_data)
		}

	case Delete_Stmt:
		walk_list(n.using_clause, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.returning_list, visitor, user_data)
		if n.with_clause != nil {
			walk_list(n.with_clause.ctes, visitor, user_data)
		}

	case Truncate_Stmt:
		walk_list(n.relations, visitor, user_data)

	case Explain_Stmt:
		walk(n.query, visitor, user_data)
		walk_list(n.options, visitor, user_data)

	case Copy_Stmt:
		walk(n.query, visitor, user_data)
		walk_list(n.attlist, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.where_clause, visitor, user_data)

	// Expressions
	case A_Expr:
		walk_list(n.name, visitor, user_data)
		walk(n.lexpr, visitor, user_data)
		walk(n.rexpr, visitor, user_data)

	case Bool_Expr:
		walk_list(n.args, visitor, user_data)

	case Func_Call:
		walk_list(n.funcname, visitor, user_data)
		walk_list(n.args, visitor, user_data)
		walk_list(n.agg_order, visitor, user_data)
		walk(n.agg_filter, visitor, user_data)

	case Type_Cast:
		walk(n.arg, visitor, user_data)

	case Case_Expr:
		walk(n.arg, visitor, user_data)
		walk_list(n.args, visitor, user_data)
		walk(n.defresult, visitor, user_data)

	case Case_When:
		walk(n.expr, visitor, user_data)
		walk(n.result, visitor, user_data)

	case Sub_Link:
		walk(n.testexpr, visitor, user_data)
		walk_list(n.oper_name, visitor, user_data)
		walk(n.subselect, visitor, user_data)

	case Coalesce_Expr:
		walk_list(n.args, visitor, user_data)

	case Null_Test:
		walk(n.arg, visitor, user_data)

	case Boolean_Test:
		walk(n.arg, visitor, user_data)

	case Row_Expr:
		walk_list(n.args, visitor, user_data)
		walk_list(n.colnames, visitor, user_data)

	case A_Array_Expr:
		walk_list(n.elements, visitor, user_data)

	case A_Indices:
		walk(n.lidx, visitor, user_data)
		walk(n.uidx, visitor, user_data)

	case A_Indirection:
		walk(n.arg, visitor, user_data)
		walk_list(n.indirection, visitor, user_data)

	case Min_Max_Expr:
		walk_list(n.args, visitor, user_data)

	case Xml_Expr:
		walk_list(n.named_args, visitor, user_data)
		walk_list(n.arg_names, visitor, user_data)
		walk_list(n.args, visitor, user_data)

	case Paren_Expr:
		walk(n.arg, visitor, user_data)

	// References
	case Column_Ref:
		walk_list(n.fields, visitor, user_data)

	case Range_Subselect:
		walk(n.subquery, visitor, user_data)

	case Range_Function:
		walk_list(n.functions, visitor, user_data)
		walk_list(n.coldeflist, visitor, user_data)

	case Join_Expr:
		walk(n.larg, visitor, user_data)
		walk(n.rarg, visitor, user_data)
		walk_list(n.using_clause, visitor, user_data)
		walk(n.quals, visitor, user_data)

	// Types / Definitions
	case Res_Target:
		walk_list(n.indirection, visitor, user_data)
		walk(n.val, visitor, user_data)

	case Column_Def:
		walk(n.raw_default, visitor, user_data)
		walk(n.cooked_default, visitor, user_data)
		walk(n.coll_clause, visitor, user_data)
		walk_list(n.constraints, visitor, user_data)
		walk_list(n.fdwoptions, visitor, user_data)

	case Constraint:
		walk(n.raw_expr, visitor, user_data)
		walk_list(n.keys, visitor, user_data)
		walk_list(n.including, visitor, user_data)
		walk_list(n.exclusions, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.fk_attrs, visitor, user_data)
		walk_list(n.pk_attrs, visitor, user_data)
		walk_list(n.fk_del_set_cols, visitor, user_data)

	case Sort_By:
		walk(n.node, visitor, user_data)
		walk_list(n.use_op, visitor, user_data)

	case Window_Def:
		walk_list(n.partition_clause, visitor, user_data)
		walk_list(n.order_clause, visitor, user_data)
		walk(n.start_offset, visitor, user_data)
		walk(n.end_offset, visitor, user_data)

	case Locking_Clause:
		walk_list(n.locked_rels, visitor, user_data)

	case On_Conflict_Clause:
		walk(n.infer, visitor, user_data)
		walk_list(n.target_list, visitor, user_data)
		walk(n.where_clause, visitor, user_data)

	case Infer_Clause:
		walk_list(n.index_elems, visitor, user_data)
		walk(n.where_clause, visitor, user_data)

	case Index_Elem:
		walk(n.expr, visitor, user_data)
		walk_list(n.collation, visitor, user_data)
		walk_list(n.opclass, visitor, user_data)
		walk_list(n.opclassopts, visitor, user_data)

	case Multi_Assign_Ref:
		walk(n.source, visitor, user_data)

	case Grouping_Set:
		walk_list(n.content, visitor, user_data)

	case Into_Clause:
		walk_list(n.col_names, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.view_query, visitor, user_data)

	// Containers
	case List:
		walk_list(n.items, visitor, user_data)

	case Raw_Stmt:
		walk(n.stmt, visitor, user_data)

	case With_Clause:
		walk_list(n.ctes, visitor, user_data)

	case Common_Table_Expr:
		walk_list(n.aliascolnames, visitor, user_data)
		walk(n.ctequery, visitor, user_data)
		walk_list(n.ctecolnames, visitor, user_data)

	// DDL
	case Create_Table_Stmt:
		walk_list(n.table_elts, visitor, user_data)
		walk_list(n.inh_relations, visitor, user_data)
		walk(n.partbound, visitor, user_data)
		walk(n.partspec, visitor, user_data)
		walk_list(n.constraints, visitor, user_data)
		walk_list(n.options, visitor, user_data)

	case Alter_Table_Stmt:
		walk_list(n.cmds, visitor, user_data)

	case Alter_Table_Cmd:
		walk(n.newowner, visitor, user_data)
		walk(n.def, visitor, user_data)

	case Drop_Stmt:
		walk_list(n.objects, visitor, user_data)

	case Create_Enum_Stmt:
		walk_list(n.type_name, visitor, user_data)
		walk_list(n.vals, visitor, user_data)

	case Alter_Enum_Stmt:
		walk_list(n.type_name, visitor, user_data)

	case Create_Function_Stmt:
		walk_list(n.funcname, visitor, user_data)
		walk_list(n.parameters, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.sql_body, visitor, user_data)

	case Function_Parameter:
		walk(n.defexpr, visitor, user_data)

	case Drop_Function_Stmt:
		walk_list(n.objects, visitor, user_data)

	case Create_Schema_Stmt:
		walk(n.authrole, visitor, user_data)
		walk_list(n.schema_elts, visitor, user_data)

	case Create_View_Stmt:
		walk_list(n.aliases, visitor, user_data)
		walk(n.query, visitor, user_data)
		walk_list(n.options, visitor, user_data)

	case Create_Table_As_Stmt:
		walk(n.query, visitor, user_data)

	case Rename_Stmt:
		walk(n.object, visitor, user_data)

	case Comment_Stmt:
		walk(n.object, visitor, user_data)

	case Alter_Object_Schema_Stmt:
		walk(n.object, visitor, user_data)

	case Create_Extension_Stmt:
		walk_list(n.options, visitor, user_data)

	case Composite_Type_Stmt:
		walk_list(n.coldeflist, visitor, user_data)

	case Index_Stmt:
		walk_list(n.index_params, visitor, user_data)
		walk_list(n.index_including_params, visitor, user_data)
		walk_list(n.options, visitor, user_data)
		walk(n.where_clause, visitor, user_data)
		walk_list(n.exclude_op_names, visitor, user_data)

	case Create_Seq_Stmt:
		walk_list(n.options, visitor, user_data)

	case Alter_Seq_Stmt:
		walk_list(n.options, visitor, user_data)

	case Grant_Stmt:
		walk_list(n.objects, visitor, user_data)
		walk_list(n.privileges, visitor, user_data)
		walk_list(n.grantees, visitor, user_data)
		walk(n.grantor, visitor, user_data)

	case Def_Elem:
		walk(n.arg, visitor, user_data)

	case Transaction_Stmt:
		walk_list(n.options, visitor, user_data)

	case Do_Stmt:
		walk_list(n.args, visitor, user_data)

	case Prepare_Stmt:
		walk_list(n.argtypes, visitor, user_data)
		walk(n.query, visitor, user_data)

	case Execute_Stmt:
		walk_list(n.params, visitor, user_data)

	// Leaf nodes (no children): A_Const, String_Node, Integer_Node,
	// Float_Node, Boolean_Node, A_Star, Param_Ref, Sql_Value_Function,
	// Set_To_Default, Role_Spec, Drop_Schema_Stmt, Table_Name, Func_Name
	// — no case needed (handled by #partial switch default)
	}
}

// Walk a list of node pointers.
walk_list :: proc(nodes: [dynamic]^Node, visitor: Visitor, user_data: rawptr) {
	for node in nodes {
		walk(node, visitor, user_data)
	}
}

// Apply transform to all children (internal).
apply_children :: proc(node: ^Node, transform: proc(^Node) -> ^Node) {
	if node == nil { return }

	apply_to_list :: proc(nodes: [dynamic]^Node, transform: proc(^Node) -> ^Node) {
		for i := 0; i < len(nodes); i += 1 {
			if nodes[i] != nil {
				apply(nodes[i], transform)
			}
		}
	}

	apply_to_node :: proc(n: ^Node, transform: proc(^Node) -> ^Node) {
		if n != nil { apply(n, transform) }
	}

	// Mirror walk_children structure but call apply recursively
	#partial switch &n in node^ {
	case Select_Stmt:
		apply_to_list(n.target_list, transform)
		apply_to_list(n.from_clause, transform)
		apply_to_node(n.where_clause, transform)
		apply_to_list(n.group_clause, transform)
		apply_to_node(n.having_clause, transform)
		apply_to_list(n.sort_clause, transform)
		apply_to_node(n.limit_offset, transform)
		apply_to_node(n.limit_count, transform)

	case Insert_Stmt:
		apply_to_list(n.cols, transform)
		apply_to_node(n.select_stmt, transform)
		apply_to_list(n.returning_list, transform)

	case Update_Stmt:
		apply_to_list(n.target_list, transform)
		apply_to_node(n.where_clause, transform)
		apply_to_list(n.from_clause, transform)
		apply_to_list(n.returning_list, transform)

	case Delete_Stmt:
		apply_to_list(n.using_clause, transform)
		apply_to_node(n.where_clause, transform)
		apply_to_list(n.returning_list, transform)

	case A_Expr:
		apply_to_node(n.lexpr, transform)
		apply_to_node(n.rexpr, transform)

	case Bool_Expr:
		apply_to_list(n.args, transform)

	case Func_Call:
		apply_to_list(n.args, transform)
		apply_to_node(n.agg_filter, transform)

	case Case_Expr:
		apply_to_node(n.arg, transform)
		apply_to_list(n.args, transform)
		apply_to_node(n.defresult, transform)

	case Case_When:
		apply_to_node(n.expr, transform)
		apply_to_node(n.result, transform)

	case Sub_Link:
		apply_to_node(n.testexpr, transform)
		apply_to_node(n.subselect, transform)

	case Coalesce_Expr:
		apply_to_list(n.args, transform)

	case Null_Test:
		apply_to_node(n.arg, transform)

	case Column_Ref:
		apply_to_list(n.fields, transform)

	case Res_Target:
		apply_to_node(n.val, transform)

	case Join_Expr:
		apply_to_node(n.larg, transform)
		apply_to_node(n.rarg, transform)
		apply_to_node(n.quals, transform)

	case List:
		apply_to_list(n.items, transform)

	case Raw_Stmt:
		apply_to_node(n.stmt, transform)
	}
}
```

- [ ] **Step 3: Run walk tests**

Run: `odin test ast/tests/`
Expected: All tests pass (walk + convert + node tests)

- [ ] **Step 4: Commit**

```bash
git add ast/walk.odin ast/tests/walk_test.odin
git commit -m "feat(ast): add AST traversal with walk, search, and apply"
```

---

## Task 8: ast/format.odin — SQL Formatting

**Files:**
- Create: `ast/format.odin`
- Create: `ast/tests/format_test.odin`

PostgreSQL-only SQL formatter. Reconstructs SQL from AST nodes using a `strings.Builder`. Only handles node types involved in query rewriting and output.

- [ ] **Step 1: Write format tests**

Create `ast/tests/format_test.odin`:

```odin
package ast_tests

import "core:testing"
import ast "../"

@(test)
test_format_column_ref :: proc(t: ^testing.T) {
	s := new(ast.Node)
	s^ = ast.String_Node{sval = "id"}
	cr := new(ast.Node)
	cr^ = ast.Column_Ref{fields = {s}}
	result := ast.format_node(cr)
	testing.expect_value(t, result, "id")
}

@(test)
test_format_qualified_column :: proc(t: ^testing.T) {
	s1 := new(ast.Node)
	s1^ = ast.String_Node{sval = "users"}
	s2 := new(ast.Node)
	s2^ = ast.String_Node{sval = "id"}
	cr := new(ast.Node)
	cr^ = ast.Column_Ref{fields = {s1, s2}}
	result := ast.format_node(cr)
	testing.expect_value(t, result, "users.id")
}

@(test)
test_format_star :: proc(t: ^testing.T) {
	star := new(ast.Node)
	star^ = ast.A_Star{}
	cr := new(ast.Node)
	cr^ = ast.Column_Ref{fields = {star}}
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
```

- [ ] **Step 2: Write ast/format.odin**

```odin
package ast

import "core:strings"
import "core:fmt"

// PostgreSQL reserved keywords that need quoting.
RESERVED_KEYWORDS :: [?]string{
	"all", "analyse", "analyze", "and", "any", "array", "as", "asc",
	"asymmetric", "both", "case", "cast", "check", "collate", "column",
	"constraint", "create", "current_catalog", "current_date", "current_role",
	"current_time", "current_timestamp", "current_user", "default",
	"deferrable", "desc", "distinct", "do", "else", "end", "except",
	"false", "fetch", "for", "foreign", "from", "grant", "group",
	"having", "in", "initially", "intersect", "into", "lateral",
	"leading", "limit", "localtime", "localtimestamp", "not", "null",
	"offset", "on", "only", "or", "order", "placing", "primary",
	"references", "returning", "select", "session_user", "some",
	"symmetric", "table", "then", "to", "trailing", "true", "union",
	"unique", "user", "using", "variadic", "when", "where", "window", "with",
}

// Check if an identifier needs quoting.
needs_quoting :: proc(s: string) -> bool {
	for kw in RESERVED_KEYWORDS {
		if strings.equal_fold(s, kw) { return true }
	}
	return false
}

// Quote a PostgreSQL identifier if needed.
quote_ident :: proc(s: string, buf: ^strings.Builder) {
	if needs_quoting(s) {
		strings.write_byte(buf, '"')
		strings.write_string(buf, s)
		strings.write_byte(buf, '"')
	} else {
		strings.write_string(buf, s)
	}
}

// Format an AST node to SQL string.
format_node :: proc(node: ^Node, allocator := context.allocator) -> string {
	if node == nil { return "" }
	buf := strings.builder_make(allocator)
	format_node_to(&buf, node)
	return strings.to_string(buf)
}

// Format an AST node to an existing builder.
format_node_to :: proc(buf: ^strings.Builder, node: ^Node) {
	if node == nil { return }

	#partial switch n in node^ {
	case String_Node:
		strings.write_string(buf, n.sval)

	case Integer_Node:
		fmt.sbprintf(buf, "%d", n.ival)

	case Float_Node:
		strings.write_string(buf, n.fval)

	case Boolean_Node:
		strings.write_string(buf, n.boolval ? "true" : "false")

	case A_Star:
		strings.write_byte(buf, '*')

	case A_Const:
		switch n.type {
		case .Integer:
			fmt.sbprintf(buf, "%d", n.ival)
		case .Float:
			strings.write_string(buf, n.fval)
		case .String:
			strings.write_byte(buf, '\'')
			// Escape single quotes
			for ch in n.sval {
				if ch == '\'' {
					strings.write_string(buf, "''")
				} else {
					strings.write_rune(buf, ch)
				}
			}
			strings.write_byte(buf, '\'')
		case .Boolean:
			strings.write_string(buf, n.bval ? "true" : "false")
		case .Null:
			strings.write_string(buf, "NULL")
		case .Bit_String:
			strings.write_string(buf, n.bsval)
		}

	case Param_Ref:
		fmt.sbprintf(buf, "$%d", n.number)

	case Column_Ref:
		for field, i in n.fields {
			if i > 0 { strings.write_byte(buf, '.') }
			format_node_to(buf, field)
		}

	case Type_Cast:
		format_node_to(buf, n.arg)
		strings.write_string(buf, "::")
		if n.type_name != nil {
			format_type_name(buf, n.type_name)
		}

	case Func_Call:
		format_func_name(buf, n.funcname)
		strings.write_byte(buf, '(')
		if n.agg_star {
			strings.write_byte(buf, '*')
		} else {
			if n.agg_distinct {
				strings.write_string(buf, "DISTINCT ")
			}
			format_node_list(buf, n.args, ", ")
		}
		strings.write_byte(buf, ')')

	case Res_Target:
		format_node_to(buf, n.val)
		if len(n.name) > 0 {
			strings.write_string(buf, " AS ")
			quote_ident(n.name, buf)
		}

	case Bool_Expr:
		switch n.boolop {
		case .Not:
			strings.write_string(buf, "NOT ")
			if len(n.args) > 0 {
				format_node_to(buf, n.args[0])
			}
		case .And:
			format_node_list(buf, n.args, " AND ")
		case .Or:
			strings.write_byte(buf, '(')
			format_node_list(buf, n.args, " OR ")
			strings.write_byte(buf, ')')
		}

	case Null_Test:
		format_node_to(buf, n.arg)
		switch n.nulltesttype {
		case .Is_Null:     strings.write_string(buf, " IS NULL")
		case .Is_Not_Null: strings.write_string(buf, " IS NOT NULL")
		}

	case Coalesce_Expr:
		strings.write_string(buf, "COALESCE(")
		format_node_list(buf, n.args, ", ")
		strings.write_byte(buf, ')')

	case A_Expr:
		if n.lexpr != nil {
			format_node_to(buf, n.lexpr)
			strings.write_byte(buf, ' ')
		}
		format_a_expr_op(buf, n.name)
		if n.rexpr != nil {
			strings.write_byte(buf, ' ')
			format_node_to(buf, n.rexpr)
		}

	case Range_Var:
		if len(n.schemaname) > 0 {
			quote_ident(n.schemaname, buf)
			strings.write_byte(buf, '.')
		}
		quote_ident(n.relname, buf)
		if n.alias != nil && len(n.alias.aliasname) > 0 {
			strings.write_byte(buf, ' ')
			quote_ident(n.alias.aliasname, buf)
		}

	case List:
		format_node_list(buf, n.items, ", ")
	}
}

// Format a TypeName to SQL.
format_type_name :: proc(buf: ^strings.Builder, tn: ^Type_Name) {
	if tn == nil { return }
	if len(tn.schema) > 0 && tn.schema != "pg_catalog" {
		quote_ident(tn.schema, buf)
		strings.write_byte(buf, '.')
	}
	strings.write_string(buf, tn.name)
	if len(tn.array_bounds) > 0 {
		strings.write_string(buf, "[]")
	}
}

// Format function name from list of String nodes.
format_func_name :: proc(buf: ^strings.Builder, names: [dynamic]^Node) {
	for n, i in names {
		if i > 0 { strings.write_byte(buf, '.') }
		if n == nil { continue }
		if s, ok := n^.(String_Node); ok {
			strings.write_string(buf, s.sval)
		}
	}
}

// Format operator name from list of String nodes.
format_a_expr_op :: proc(buf: ^strings.Builder, names: [dynamic]^Node) {
	for n in names {
		if n == nil { continue }
		if s, ok := n^.(String_Node); ok {
			strings.write_string(buf, s.sval)
		}
	}
}

// Format a comma-separated list of nodes.
format_node_list :: proc(buf: ^strings.Builder, nodes: [dynamic]^Node, sep: string) {
	first := true
	for n in nodes {
		if !first { strings.write_string(buf, sep) }
		format_node_to(buf, n)
		first = false
	}
}
```

- [ ] **Step 3: Run format tests**

Run: `odin test ast/tests/`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add ast/format.odin ast/tests/format_test.odin
git commit -m "feat(ast): add SQL formatter for AST nodes"
```

---

## Summary

After completing all 8 tasks, we have:

- **source/ package**: Text manipulation utilities (pluck, mutate, strip_comments, line_number)
- **ast/convert.odin**: Complete JSON→AST dispatch with ~80 node converters
- **ast/translate.odin**: DDL semantic translation (NOT NULL detection, primary key extraction)
- **ast/walk.odin**: Depth-first AST traversal, search, and apply
- **ast/format.odin**: PostgreSQL SQL formatter for AST nodes
- **Tests**: Integration tests parsing real SQL through the full pipeline

**Next plan** will cover: `catalog/` (database schema representation), `metadata/` (query annotation parsing), and `compiler/` (the main compilation pipeline).
