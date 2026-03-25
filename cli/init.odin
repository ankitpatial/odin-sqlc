package cli

import "core:fmt"
import "core:os"

INIT_TEMPLATE :: `{
  "version": "1",
  "sql": [
    {
      "schema": ["sql/schema.sql"],
      "queries": ["sql/query.sql"],
      "engine": "postgresql",
      "gen": {
        "odin": {
          "package": "db",
          "out": "db"
        }
      }
    }
  ]
}
`

cmd_init :: proc(args: []string) {
	filename := "sqld.json"

	// Check if file already exists
	if os.exists(filename) {
		fmt.eprintf("error: %s already exists\n", filename)
		os.exit(1)
	}

	write_err := os.write_entire_file_from_string(filename, INIT_TEMPLATE)
	if write_err != nil {
		fmt.eprintf("error: could not write %s\n", filename)
		os.exit(1)
	}

	fmt.printf("Created %s\n", filename)
}
