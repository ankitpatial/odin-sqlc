package pg_query_tests

import "core:encoding/json"
import "core:testing"
import pq "../"

@(test)
test_parse_simple_select :: proc(t: ^testing.T) {
	stmts, err := pq.parse("SELECT 1")
	defer delete(stmts)

	testing.expect(t, err == nil, "expected no error parsing SELECT 1")
	testing.expect_value(t, len(stmts), 1)

	if len(stmts) > 0 {
		obj, ok := stmts[0].stmt_json.(json.Object)
		testing.expect(t, ok, "expected stmt_json to be a JSON object")
		if ok {
			_, has_key := obj["SelectStmt"]
			testing.expect(t, has_key, "expected SelectStmt key in parsed JSON")
		}
	}
}

@(test)
test_parse_create_table :: proc(t: ^testing.T) {
	stmts, err := pq.parse("CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT NOT NULL)")
	defer delete(stmts)

	testing.expect(t, err == nil, "expected no error parsing CREATE TABLE")
	testing.expect_value(t, len(stmts), 1)

	if len(stmts) > 0 {
		obj, ok := stmts[0].stmt_json.(json.Object)
		testing.expect(t, ok, "expected stmt_json to be a JSON object")
		if ok {
			_, has_key := obj["CreateStmt"]
			testing.expect(t, has_key, "expected CreateStmt key in parsed JSON")
		}
	}
}

@(test)
test_parse_multiple_statements :: proc(t: ^testing.T) {
	stmts, err := pq.parse("SELECT 1; SELECT 2; SELECT 3")
	defer delete(stmts)

	testing.expect(t, err == nil, "expected no error parsing multiple statements")
	testing.expect_value(t, len(stmts), 3)
}

@(test)
test_parse_insert :: proc(t: ^testing.T) {
	stmts, err := pq.parse("INSERT INTO users (name) VALUES ('test')")
	defer delete(stmts)

	testing.expect(t, err == nil, "expected no error parsing INSERT")
	testing.expect_value(t, len(stmts), 1)

	if len(stmts) > 0 {
		obj, ok := stmts[0].stmt_json.(json.Object)
		testing.expect(t, ok, "expected stmt_json to be a JSON object")
		if ok {
			_, has_key := obj["InsertStmt"]
			testing.expect(t, has_key, "expected InsertStmt key in parsed JSON")
		}
	}
}

@(test)
test_parse_error :: proc(t: ^testing.T) {
	stmts, err := pq.parse("SELCT 1")
	defer delete(stmts)

	e, has_err := err.?
	testing.expect(t, has_err, "expected an error for invalid SQL")
	if has_err {
		testing.expect(t, len(e.message) > 0, "expected non-empty error message")
	}
}

@(test)
test_parse_empty :: proc(t: ^testing.T) {
	stmts, err := pq.parse("")
	defer delete(stmts)

	testing.expect(t, err == nil, "expected no error parsing empty string")
	testing.expect_value(t, len(stmts), 0)
}

@(test)
test_parse_statement_locations :: proc(t: ^testing.T) {
	stmts, err := pq.parse("SELECT 1; SELECT 2")
	defer delete(stmts)

	testing.expect(t, err == nil, "expected no error")
	testing.expect_value(t, len(stmts), 2)

	if len(stmts) >= 2 {
		testing.expect(t, stmts[1].location > 0, "expected second statement location > 0")
	}
}

@(test)
test_normalize :: proc(t: ^testing.T) {
	result, err := pq.normalize("SELECT * FROM users WHERE id = 42 AND name = 'test'")

	testing.expect(t, err == nil, "expected no error from normalize")
	testing.expect(t, len(result) > 0, "expected non-empty normalized query")
}

@(test)
test_fingerprint :: proc(t: ^testing.T) {
	fp1, err1 := pq.fingerprint("SELECT * FROM users WHERE id = 1")
	fp2, err2 := pq.fingerprint("SELECT * FROM users WHERE id = 999")

	testing.expect(t, err1 == nil, "expected no error from fingerprint (query 1)")
	testing.expect(t, err2 == nil, "expected no error from fingerprint (query 2)")
	testing.expect(t, len(fp1) > 0, "expected non-empty fingerprint")
	testing.expect_value(t, fp1, fp2)
}
