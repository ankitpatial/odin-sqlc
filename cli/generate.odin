package cli

import "core:fmt"
import "core:os"

cmd_generate :: proc(args: []string) {
	fmt.eprintln("error: 'sqld generate' is not yet implemented")
	fmt.eprintln()
	fmt.eprintln("The following components are still needed:")
	fmt.eprintln("  - catalog/   (database schema representation)")
	fmt.eprintln("  - compiler/  (query analysis and type inference)")
	fmt.eprintln("  - codegen/   (Odin code generation)")
	fmt.eprintln()
	fmt.eprintln("Available commands:")
	fmt.eprintln("  sqld compile   Check SQL syntax")
	fmt.eprintln("  sqld parse     Show parsed AST")
	os.exit(1)
}
