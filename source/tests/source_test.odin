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
