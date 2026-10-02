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

## Keys

| Key | Command | Does |
|---|---|---|
| `h` / `l` | `parry-prev` / `parry-next` | Previous / next sibling |
| `j` / `J` | `parry-first-child` / `parry-last-child` | First / last child |
| `k` | `parry-parent` | Enclosing form |
| `i` / `a` | `parry-insert-before` / `parry-insert-after` | Add a space (or a new indented line, if the node sits on its own line), then Insert mode before / after the node |
| `c` | `parry-change` | Replace the atom (not a form) with Insert mode |
| `(` `)` `[` `]` `{` `}` | new form | Empty form before (open bracket) / after (close bracket) the node, Insert mode inside it. One pair per dialect bracket |
| `;` | `parry-new-comment` | New comment line above the node |
| `s` / `S` | `parry-slurp-forward` / `-backward` | Enclosing form takes in the next / previous sibling |
| `b` / `B` | `parry-barf-forward` / `-backward` | Push the form's last / first element out |
| `A-l` / `A-h` | `parry-swap-next` / `parry-swap-prev` | Swap the node with its next / previous sibling (it stays selected, so repeat to keep moving it; steps over comments, which stay where they are) |
| `r` | `parry-raise` | Replace the parent form with the node |
| `w` | `parry-wrap` | Wrap the node in the dialect's first bracket pair |
| `W` | `parry-splice` | Remove the enclosing form's brackets |
| `d` | `parry-delete` | Delete the node; select the next sibling, else the previous, else the parent |
| `m` | `parry-toggle-layout` | Toggle the siblings after the node between one line and one per line (a top-level form: all its children) |
| `u` / `U` | `parry-undo` / `parry-redo` | Undo / redo, then select the node there |
| `Esc` | | Leave Parry |
| `:` `space` `v` | | Passed to Helix: typed commands, the space menu, Select mode |

`A-` means Alt. On macOS your terminal has to send Option as Alt/Meta for
these (e.g. Ghostty `macos-option-as-alt = true`, iTerm2 "Esc+" for Option).

Change the pass-through keys with `(set-parry-pass-through! '(":" "space" "v" "g"))`.
A passed-through key that starts a Helix key sequence (like `space`) keeps
passing keys through until the sequence is complete.

Every command is also a typed command (`:parry-slurp-forward`, ...), so you
can bind them in other modes too.

While Parry is active the status line shows `PARRY`, and the Normal-mode cursor
is hidden so the selected node shows as one solid highlight. Your cursor shape
comes back when you leave Parry or switch to a buffer without a dialect.

The first character of every other node at the current level is marked (with
your theme's `ui.cursor.match` style), so you can see where `h`/`l` go. Change
the style with `set-parry-sibling-style!`, e.g.
`(set-parry-sibling-style! (style-with-bold (style-fg (style) Color/Cyan)))`
after requiring `helix/components.scm`.

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
