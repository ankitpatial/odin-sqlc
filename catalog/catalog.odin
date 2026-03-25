package catalog

import "../ast"

Column :: struct {
	name:      string,
	data_type: string, // pg type name (e.g. "text", "integer", "serial")
	not_null:  bool,
	is_array:  bool,
	comment:   string,
}

Table :: struct {
	name:    string,
	schema:  string,
	columns: [dynamic]Column,
	comment: string,
}

Enum_Type :: struct {
	name:    string,
	schema:  string,
	vals:    [dynamic]string,
	comment: string,
}

Catalog :: struct {
	tables: [dynamic]Table,
	enums:  [dynamic]Enum_Type,
}

// Build a catalog by processing a sequence of DDL AST nodes.
build :: proc(nodes: []^ast.Node, allocator := context.allocator) -> Catalog {
	c := Catalog{
		tables = make([dynamic]Table, 0, 16, allocator),
		enums  = make([dynamic]Enum_Type, 0, 8, allocator),
	}
	for node in nodes {
		update(&c, node, allocator)
	}
	return c
}

// Update catalog with a single DDL statement.
update :: proc(c: ^Catalog, node: ^ast.Node, allocator := context.allocator) {
	if node == nil { return }

	#partial switch n in node^ {
	case ast.Create_Table_Stmt:
		update_create_table(c, n, allocator)
	case ast.Create_Enum_Stmt:
		update_create_enum(c, n, allocator)
	case ast.Alter_Table_Stmt:
		update_alter_table(c, n, allocator)
	case ast.Alter_Enum_Stmt:
		update_alter_enum(c, n, allocator)
	case ast.Drop_Stmt:
		update_drop(c, n)
	case ast.Rename_Stmt:
		update_rename(c, n, allocator)
	case ast.Comment_Stmt:
		update_comment(c, n, allocator)
	case ast.Composite_Type_Stmt:
		// ignore for now
	case ast.Create_View_Stmt:
		// ignore for now
	case ast.Create_Extension_Stmt:
		// ignore for now
	case ast.Index_Stmt:
		// indexes don't affect the catalog schema
	}
}

update_create_table :: proc(c: ^Catalog, ct: ast.Create_Table_Stmt, allocator := context.allocator) {
	name := ct.relation != nil ? ct.relation.relname : ""
	schema := ct.relation != nil ? ct.relation.schemaname : ""
	if len(name) == 0 { return }

	cols := make([dynamic]Column, 0, len(ct.table_elts), allocator)
	for elt in ct.table_elts {
		if elt == nil { continue }
		if cd, ok := elt^.(ast.Column_Def); ok {
			col := column_from_def(cd, allocator)
			append(&cols, col)
		}
	}

	append(&c.tables, Table{
		name    = name,
		schema  = schema,
		columns = cols,
	})
}

update_create_enum :: proc(c: ^Catalog, ce: ast.Create_Enum_Stmt, allocator := context.allocator) {
	name := ""
	schema := ""
	for n in ce.type_name {
		if n == nil { continue }
		if s, ok := n^.(ast.String_Node); ok {
			if len(name) == 0 {
				name = s.sval
			} else {
				schema = name
				name = s.sval
			}
		}
	}
	if len(name) == 0 { return }

	vals := make([dynamic]string, 0, len(ce.vals), allocator)
	for v in ce.vals {
		if v == nil { continue }
		if s, ok := v^.(ast.String_Node); ok {
			append(&vals, s.sval)
		}
	}

	append(&c.enums, Enum_Type{
		name   = name,
		schema = schema,
		vals   = vals,
	})
}

update_alter_table :: proc(c: ^Catalog, at: ast.Alter_Table_Stmt, allocator := context.allocator) {
	name := at.relation != nil ? at.relation.relname : ""
	tbl := find_table(c, name)
	if tbl == nil { return }

	for cmd_node in at.cmds {
		if cmd_node == nil { continue }
		cmd, ok := cmd_node^.(ast.Alter_Table_Cmd)
		if !ok { continue }

		#partial switch cmd.subtype {
		case .Add_Column:
			if cmd.def != nil {
				if cd, cdok := cmd.def^.(ast.Column_Def); cdok {
					col := column_from_def(cd, allocator)
					append(&tbl.columns, col)
				}
			}
		case .Drop_Column:
			drop_column(tbl, cmd.name)
		case .Alter_Column_Type:
			if col := find_column(tbl, cmd.name); col != nil {
				if cmd.def != nil {
					if cd, cdok := cmd.def^.(ast.Column_Def); cdok {
						if cd.type_name != nil {
							col.data_type = cd.type_name.name
							col.is_array = len(cd.type_name.array_bounds) > 0
						}
					}
				}
			}
		case .Alter_Column_Set_Not_Null:
			if col := find_column(tbl, cmd.name); col != nil {
				col.not_null = true
			}
		case .Alter_Column_Drop_Not_Null:
			if col := find_column(tbl, cmd.name); col != nil {
				col.not_null = false
			}
		case .Rename_Column:
			// handled by Rename_Stmt
		}
	}
}

update_alter_enum :: proc(c: ^Catalog, ae: ast.Alter_Enum_Stmt, allocator := context.allocator) {
	name := ""
	for n in ae.type_name {
		if n == nil { continue }
		if s, ok := n^.(ast.String_Node); ok {
			name = s.sval
		}
	}
	e := find_enum(c, name)
	if e == nil { return }
	if len(ae.new_val) > 0 {
		append(&e.vals, ae.new_val)
	}
}

update_drop :: proc(c: ^Catalog, d: ast.Drop_Stmt) {
	#partial switch d.remove_type {
	case .Table:
		for obj in d.objects {
			if obj == nil { continue }
			if l, ok := obj^.(ast.List); ok {
				for item in l.items {
					if item == nil { continue }
					if s, sok := item^.(ast.String_Node); sok {
						remove_table(c, s.sval)
					}
				}
			}
		}
	case .Type:
		for obj in d.objects {
			if obj == nil { continue }
			if l, ok := obj^.(ast.List); ok {
				for item in l.items {
					if item == nil { continue }
					if s, sok := item^.(ast.String_Node); sok {
						remove_enum(c, s.sval)
					}
				}
			}
		}
	}
}

update_rename :: proc(c: ^Catalog, r: ast.Rename_Stmt, allocator := context.allocator) {
	#partial switch r.rename_type {
	case .Table:
		name := r.relation != nil ? r.relation.relname : ""
		tbl := find_table(c, name)
		if tbl != nil {
			tbl.name = r.newname
		}
	case .Function:
		// ignore
	}

	// Column rename: rename_type is Table but subname and newname are set
	if r.relation != nil && len(r.subname) > 0 && len(r.newname) > 0 {
		name := r.relation.relname
		tbl := find_table(c, name)
		if tbl != nil {
			if col := find_column(tbl, r.subname); col != nil {
				col.name = r.newname
			}
		}
	}
}

update_comment :: proc(c: ^Catalog, cm: ast.Comment_Stmt, allocator := context.allocator) {
	#partial switch cm.objtype {
	case .Table:
		if cm.object != nil {
			if l, ok := cm.object^.(ast.List); ok {
				for item in l.items {
					if item == nil { continue }
					if s, sok := item^.(ast.String_Node); sok {
						tbl := find_table(c, s.sval)
						if tbl != nil {
							tbl.comment = cm.comment
						}
					}
				}
			}
		}
	case .Type:
		if cm.object != nil {
			if l, ok := cm.object^.(ast.List); ok {
				for item in l.items {
					if item == nil { continue }
					if s, sok := item^.(ast.String_Node); sok {
						e := find_enum(c, s.sval)
						if e != nil {
							e.comment = cm.comment
						}
					}
				}
			}
		}
	}
}

// ── Lookups ───────────────────────────────────────────────────

find_table :: proc(c: ^Catalog, name: string) -> ^Table {
	for &t in c.tables {
		if t.name == name { return &t }
	}
	return nil
}

find_column :: proc(tbl: ^Table, name: string) -> ^Column {
	for &col in tbl.columns {
		if col.name == name { return &col }
	}
	return nil
}

find_enum :: proc(c: ^Catalog, name: string) -> ^Enum_Type {
	for &e in c.enums {
		if e.name == name { return &e }
	}
	return nil
}

is_enum_type :: proc(c: ^Catalog, type_name: string) -> bool {
	for e in c.enums {
		if e.name == type_name { return true }
	}
	return false
}

// ── Helpers ───────────────────────────────────────────────────

column_from_def :: proc(cd: ast.Column_Def, allocator := context.allocator) -> Column {
	data_type := ""
	is_array := false
	if cd.type_name != nil {
		data_type = cd.type_name.name
		is_array = len(cd.type_name.array_bounds) > 0
	}
	return Column{
		name      = cd.colname,
		data_type = data_type,
		not_null  = cd.is_not_null,
		is_array  = is_array,
	}
}

drop_column :: proc(tbl: ^Table, name: string) {
	for i := 0; i < len(tbl.columns); i += 1 {
		if tbl.columns[i].name == name {
			ordered_remove(&tbl.columns, i)
			return
		}
	}
}

remove_table :: proc(c: ^Catalog, name: string) {
	for i := 0; i < len(c.tables); i += 1 {
		if c.tables[i].name == name {
			ordered_remove(&c.tables, i)
			return
		}
	}
}

remove_enum :: proc(c: ^Catalog, name: string) {
	for i := 0; i < len(c.enums); i += 1 {
		if c.enums[i].name == name {
			ordered_remove(&c.enums, i)
			return
		}
	}
}
