## Task Spec for OpenCode

### Objective

Publish the existing `zombiectl` Node.js CLI to npm as an **unscoped package** named:

```
zombiectl
```

The CLI structure and commands already exist in:

```
~/Projects/usezombie/docs/spec/v1/M4_001_CLI_ZOMBIECTL.md
```

The scaffold skill must generate the CLI from that spec.

---

# Inputs

CLI command specification.

```
~/Projects/usezombie/docs/spec/v1/M4_001_CLI_ZOMBIECTL.md
```

Existing scaffold skill capable of generating the CLI structure.

---

# Expected Result

After execution the project must support:

```
npm install -g zombiectl
```

and expose the command:

```
zombiectl
```

---

# Required Steps

### 1. Generate CLI

Use the scaffold skill to generate the CLI structure from:

```
docs/spec/v1/M4_001_CLI_ZOMBIECTL.md
```

Expected project root:

```
zombiectl/
```

---

### 2. Ensure npm CLI Structure

Repository must contain:

```
zombiectl/
 ├─ package.json
 ├─ README.md
 ├─ LICENSE
 ├─ bin/
 │   └─ zombiectl.js
 └─ src/
```

---

### 3. Configure CLI Entrypoint

`bin/zombiectl.js`

```
#!/usr/bin/env node
import "../src/cli.js"
```

File must be executable.

```
chmod +x bin/zombiectl.js
```

---

### 4. Configure package.json

Requirements.

```
{
  "name": "zombiectl",
  "version": "0.1.0",
  "description": "CLI for the UseZombie platform",
  "license": "MIT",
  "type": "module",
  "bin": {
    "zombiectl": "./bin/zombiectl.js"
  },
  "engines": {
    "node": ">=18"
  }
}
```

Key requirement.

```
"bin": {
  "zombiectl": "./bin/zombiectl.js"
}
```

This exposes the global CLI command.

---

### 5. Verify Name Availability

Run:

```
npm view zombiectl
```

If the registry returns **404**, the name is available.

---

### 6. Local CLI Test

Link the package locally.

```
npm link
```

Verify command.

```
zombiectl --help
```

---

### 7. Publish Package

Authenticate.

```
npm login
```

Publish.

```
npm publish --access public
```

---

# Success Criteria

The following must work.

Install.

```
npm install -g zombiectl
```

Run.

```
zombiectl
```

The CLI must implement all commands defined in:

```
docs/spec/v1/M4_001_CLI_ZOMBIECTL.md
```
