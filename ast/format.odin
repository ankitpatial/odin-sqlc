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
