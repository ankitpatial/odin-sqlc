package ast

import "core:encoding/json"
import "core:mem"

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

parse_relation_from_range_var :: proc(rv: ^Range_Var) -> Table_Name {
	if rv == nil { return {} }
	return Table_Name{
		catalog = rv.catalogname,
		schema  = rv.schemaname,
		name    = rv.relname,
	}
}

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

is_type_array :: proc(tn: ^Type_Name) -> bool {
	if tn == nil { return false }
	return len(tn.array_bounds) > 0
}

// Top-level entry point for converting parsed JSON into AST nodes.
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
			return convert_node(stmt_json, allocator)
		}
		break
	}
	return nil
}

translate_create_table :: proc(obj: json.Object, allocator: mem.Allocator) -> ^Node {
	rel := get_range_var(obj, "relation", allocator)

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

	table_elts := make([dynamic]^Node, 0, len(elts), allocator)
	for e in elts {
		if e == nil { continue }
		if cd, ok := e^.(Column_Def); ok {
			is_pk := cd.colname in primary_keys
			if is_pk {
				cd.is_not_null = true
			}
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

	raw_cmds := get_node_list(obj, "cmds", allocator)
	cmds := make([dynamic]^Node, 0, len(raw_cmds), allocator)
	for c in raw_cmds {
		if c == nil { continue }
		if cmd, ok := c^.(Alter_Table_Cmd); ok {
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
