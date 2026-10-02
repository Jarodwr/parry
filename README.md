# Parry

Structural editing for Lisp dialects in [Helix](https://helix-editor.com),
written as a Steel plugin for the
[`steel-event-system`](https://github.com/mattwparas/helix/blob/steel-event-system/STEEL.md)
fork. The selection is always a whole syntax-tree node, `h`/`j`/`k`/`l` walk
the tree, and single keys do structural edits.

Parry needs no changes to Helix. `:parry-enter` pushes an invisible component
on top of the editor that sees every key first:

- In **Normal mode in a buffer Parry knows** (see Dialects), Parry's keys run
  Parry commands, a few keys pass through to Helix, and every other key does
  nothing.
- In **Insert or Select mode**, or in **any other buffer**, every event goes
  straight to Helix. So `i` … `Esc` and `v` … `Esc` land back in Parry, and
  switching to a Markdown file gives you plain Helix there.
- `Esc` in Parry leaves it.

It edits the real buffer, so undo, saving, LSP and diagnostics all work as
usual. Each structural edit is one undo step; an Insert session started from
Parry (including the space or newline Parry adds first) is one undo step too.

## Install

1. Install a Helix built with Steel, either with Homebrew:

   ```sh
   brew install jarodwr/tap/helix-steel
   ```

   or from a checkout of the fork with `cargo xtask steel`.

2. Install Parry with forge (included in the Homebrew formula):

   ```sh
   forge pkg install --git https://github.com/Jarodwr/parry.git
   ```

   or declaratively: list it in a `cog.scm` (e.g. `~/.config/helix/cog.scm`)
   and run `forge build` in that folder:

   ```scheme
   (define package-name 'helix-config)
   (define version "0.1.0")
   (define dependencies
     '((#:name "parry" #:git-url "https://github.com/Jarodwr/parry.git" #:sha "<commit>")))
   ```

3. Load it and pick a key to enter it, in `~/.config/helix/init.scm`:

   ```scheme
   (require "parry/parry.scm")
   (require (only-in "helix/keymaps.scm" keymap))
   (keymap (global) (normal (L ":parry-enter")))
   ```

For development, run `forge install` in your checkout after each change (it
copies the package into Steel's cogs folder), then `:config-reload` in Helix
and press your enter key again.

## Commands

Every key below is also a typed command (`:parry-slurp-forward`, ...), so you
can bind them anywhere, e.g. in Insert mode. In the examples, `«»` marks the
selected node.

### 1. Getting around

Enough to read code structurally. You're always on one whole node, and these
keys walk the tree.

| Key | Command | What it does |
|---|---|---|
| your key, e.g. `L` | `parry-enter` | Enter Parry. The node under the cursor gets selected |
| `Esc` | `parry-exit` | Leave Parry, back to plain Helix |
| `l` / `h` | `parry-next` / `parry-prev` | Next / previous node at this level |
| `j` | `parry-first-child` | Into the node: its first child |
| `J` | `parry-last-child` | Into the node: its last child |
| `k` | `parry-parent` | Out: the form around this node |
| `u` / `U` | `parry-undo` / `parry-redo` | Undo / redo, then select the node there |

The first character of every other node at this level is highlighted, so you
can see where `h`/`l` go.

### 2. Typing

Each of these drops you into Helix's Insert mode in the right place. `Esc`
brings you back to Parry, with what you typed selected.

| Key | Command | What it does | Example |
|---|---|---|---|
| `a` | `parry-insert-after` | Type a new node after this one | `(f «x»)` → `(f x ▏)` |
| `i` | `parry-insert-before` | Type a new node before this one | `(f «x»)` → `(f ▏ x)` |
| `c` | `parry-change` | Replace this atom (not a form) | `(f «x»)` → `(f ▏)` |
| `)` / `(` | new form | New empty `()` after / before this node, typing inside it | `(f «x»)` → `(f x (▏))` |
| `]` / `[` | new form | Same with `[]` | `(f «x»)` → `(f x [▏])` |
| `}` / `{` | new form | Same with `{}` | `(f «x»)` → `(f x {▏})` |
| `;` | `parry-new-comment` | New comment line above this node | |

If the node sits on its own line, `a`/`i` and the new-form keys open a new,
indented line instead of adding a space. `▏` is where you start typing.

### 3. Reshaping code

Structural edits. Each one is a single undo step, and brackets always stay
balanced.

| Key | Command | What it does | Example |
|---|---|---|---|
| `d` | `parry-delete` | Delete this node | `(a «b» c)` → `(a «c»)` |
| `w` | `parry-wrap` | Wrap it in parentheses | `(a «b» c)` → `(a «(b)» c)` |
| `W` | `parry-splice` | Remove the brackets of the form around it | `(a («b» c) d)` → `(a «b» c d)` |
| `r` | `parry-raise` | Replace the form around it with just this node | `(a («b» c) d)` → `(a «b» d)` |
| `A-l` / `A-h` | `parry-swap-next` / `parry-swap-prev` | Swap it with the next / previous node; repeat to keep moving it. Steps over comments, which stay put | `(«a» b c)` → `(b «a» c)` |
| `s` | `parry-slurp-forward` | Pull the next node into the form around this one | `((«a») b)` → `(«(a b)»)` |
| `S` | `parry-slurp-backward` | Pull the previous node into the form | `(a («b»))` → `(«(a b)»)` |
| `b` | `parry-barf-forward` | Push the form's last node out after it | `((a «b»))` → `(«(a)» b)` |
| `B` | `parry-barf-backward` | Push the form's first node out before it | `((a «b»))` → `(a «(b)»)` |
| `m` | `parry-toggle-layout` | Put everything after this node on one line, or one per line | `(«a» b c)` ↔ `(a` / `  b` / `  c)` |

`A-` means Alt. On macOS your terminal has to send Option as Alt, e.g. Ghostty
`macos-option-as-alt = left` (left Option is Alt, right Option still types
special characters) or iTerm2 "Esc+" for Option.

### 4. Helix inside Parry

Parry takes over Normal mode, but these go straight to Helix:

| Key | What you get |
|---|---|
| `:` | Typed commands (`:w`, `:q`, ...) |
| `space` | The space menu: file picker, buffers, and so on. The whole key sequence goes to Helix |
| `v` | Select mode, to extend the selection with Helix's own motions. `Esc` returns to Parry on the node you selected |

Any other key does nothing while Parry is active.

### 5. Setup and configuration

Scheme functions for `init.scm`, after `(require "parry/parry.scm")`:

| Function | What it does |
|---|---|
| `(set-parry-pass-through! '(":" "space" "v" "g"))` | Choose which first keys go straight to Helix (default `:`, `space`, `v`) |
| `(set-parry-sibling-style! style)` | Style for the sibling highlights, e.g. `(style-with-bold (style-fg (style) Color/Cyan))` after requiring `helix/components.scm`. `#f` = the theme's `ui.cursor.match` |
| `(define-parry-dialect name #:extensions ... #:language ...)` | Teach Parry another Lisp dialect (see [Dialects](#dialects)) |
| `(parry-active?)` | Whether Parry is on, for your own commands |
| `:parry-self-test` | Run Parry's built-in tests (see [Testing](#testing)) |

While Parry is active the status line shows `PARRY`, and the Normal-mode cursor
is hidden so the selected node shows as one solid highlight. Your cursor shape
comes back when you leave Parry or switch to a buffer without a dialect.

## Dialects

A dialect says which files Parry acts on, which Helix language parses them,
and which node kinds play which role. The node kinds below are illustrative;
take the real ones from your grammar's `node-types.json`:

```scheme
(define-parry-dialect "scheme"
  #:extensions '("scm" "ss")
  #:language "scheme"                      ; a Helix language name
  #:containers '("list" "vector")          ; node kinds that are bracketed forms
  #:brackets '(("(" ")") ("[" "]"))        ; first pair is used by `w`
  #:comment ";"
  #:comment-kinds '("comment")
  #:string-kinds '("string"))
```

Fennel ships in `dialects/fennel.scm` as two dialects. The preferred one
parses with `fennel-sexp`, fennel-tools' plain s-expression grammar, which the
`jarodwr/tap/helix-steel` build adds as a hidden language; it only knows lists,
sequences and tables, so it copes better with half-written code. On Helix
builds without it, Parry falls back to Helix's own `fennel` grammar
(`alexmozaidze/tree-sitter-fennel`), which gives each special form its own node
kind (`fn_form`, `let_form`, ...), so all 38 bracketed kinds are listed. For an
extension, the first registered dialect whose language Helix has a grammar for
is used. Reader macros such as `#(...)`, `'x` and `` `x `` move and edit with
the form they prefix.

When `#:language` is the buffer's own language, Parry uses Helix's live tree.
Any other language name makes Parry re-parse the buffer with that grammar on
each command, which lets a dialect use a different grammar than the one Helix
highlights with. For example, to use a plain s-expression Fennel grammar: add
a language entry for it in `~/.config/helix/languages.toml` (a `[[language]]`
named e.g. `fennel-sexp` plus a `[[grammar]]` whose `source` is a local `path`
to the grammar), run `hx --grammar build`, then point the dialect's
`#:language` at `fennel-sexp` and list that grammar's container kinds. This
route is untested: check that Helix accepts a language entry used only this
way.

## Testing

`:parry-self-test` runs every operation against in-memory fixtures (no buffer
is touched) and reports the result in the status line. Details go to the Helix
log (`hx -v`, then look for `PARRY-TEST` in `~/.cache/helix/helix.log`).

## Known limits

- `:config-reload` drops out of Parry; enter it again afterwards.
- `i`/`a`/new-form add their space or newline before Insert mode starts; if you
  type nothing, it stays (one `u` removes it).
- Counts (`3s`) and `.` (repeat) don't apply to Parry keys.
- Mouse clicks go to Helix and can leave the selection off a node; the next
  Parry key re-selects the node there.
- Entering Parry keeps only the primary selection.
- Sibling marks are placed relative to the cursor's screen position (Steel has
  no general buffer-to-screen mapping), so they drift on lines with soft
  wraps, tabs or double-width characters.
- Typing in Insert mode doesn't protect bracket balance (Helix's auto-pairs
  covers the common case).
