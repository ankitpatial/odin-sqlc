package cli

import "core:fmt"
import "core:os"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		print_usage()
		os.exit(1)
	}

	command := args[1]
	cmd_args := args[2:] if len(args) > 2 else []string{}

	switch command {
	case "init":
		cmd_init(cmd_args)
	case "parse":
		cmd_parse(cmd_args)
	case "compile", "check":
		cmd_compile(cmd_args)
	case "generate", "gen":
		cmd_generate(cmd_args)
	case "version", "--version", "-v":
		cmd_version()
	case "help", "--help", "-h":
		print_usage()
	case:
		fmt.eprintf("error: unknown command '%s'\n\n", command)
		print_usage()
		os.exit(1)
	}
}

print_usage :: proc() {
	fmt.println("sqld - Generate type-safe Odin code from SQL")
	fmt.println()
	fmt.println("Usage:")
	fmt.println("  sqld <command> [flags]")
	fmt.println()
	fmt.println("Commands:")
	fmt.println("  init        Create a sqld.json config file")
	fmt.println("  compile     Check SQL for syntax errors")
	fmt.println("  parse       Parse SQL and show AST")
	fmt.println("  generate    Generate Odin code from SQL (not yet implemented)")
	fmt.println("  version     Print version")
	fmt.println()
	fmt.println("Flags:")
	fmt.println("  -f <file>   Use alternate config file (default: sqld.json)")
}
