;;; pygn-mode.el --- Major-mode for chess PGN files, powered by Python -*- lexical-binding: t -*-

;; Copyright (c) 2019-2021 Dodge Coates and Roland Walker

;; Author: Dodge Coates and Roland Walker
;; Homepage: https://github.com/dwcoates/pygn-mode
;; URL: https://raw.githubusercontent.com/dwcoates/pygn-mode/master/pygn-mode.el
;; Version: 0.6.0
;; Last-Updated: 06 Aug 2021
;; Package-Requires: ((emacs "26.1") (tree-sitter "0.15.1") (tree-sitter-langs "0.10.1") (uci-mode "0.5.4") (nav-flash "1.0.0") (ivy "0.10.0"))
;; Keywords: data, games, chess

;;; License

;; Simplified BSD License:

;; Redistribution and use in source and binary forms, with or
;; without modification, are permitted provided that the following
;; conditions are met:

;;   1. Redistributions of source code must retain the above
;;      copyright notice, this list of conditions and the following
;;      disclaimer.

;;   2. Redistributions in binary form must reproduce the above
;;      copyright notice, this list of conditions and the following
;;      disclaimer in the documentation and/or other materials
;;      provided with the distribution.

;; This software is provided by the authors "AS IS" and any express
;; or implied warranties, including, but not limited to, the implied
;; warranties of merchantability and fitness for a particular
;; purpose are disclaimed.  In no event shall the authors or
;; contributors be liable for any direct, indirect, incidental,
;; special, exemplary, or consequential damages (including, but not
;; limited to, procurement of substitute goods or services; loss of
;; use, data, or profits; or business interruption) however caused
;; and on any theory of liability, whether in contract, strict
;; liability, or tort (including negligence or otherwise) arising in
;; any way out of the use of this software, even if advised of the
;; possibility of such damage.

;; The views and conclusions contained in the software and
;; documentation are those of the authors and should not be
;; interpreted as representing official policies, either expressed
;; or implied, of the authors.

;;; Internal notes

;; Bugs

;; TODO

;;     Make forward-exit and backward-exit defuns robust against %-escaped lines
;;     Make forward-exit and backward-exit defuns robust against semicolon comments

;;     Extensive ert test coverage of
;;      - pygn-mode-pgn-at-pos
;;      - pygn-mode-pgn-at-pos-as-if-variation

;;     pygn-mode-go-searchmoves which defaults to searching move under point

;;     Flash current move on selection

;; IDEA

;;     UCI moves to pgn: UCI position command arguments to pgn and/or graphical display

;;     count games in current file? Display in modeline?

;;     evil text objects?

;;; Commentary:

;; Quickstart

;;     (require 'pygn-mode)

;;     M-x pygn-mode-run-diagnostic

;; Explanation

;;     Pygn-mode is a major-mode for viewing and editing chess PGN files.
;;     Directly editing PGN files is interesting for programmers who are
;;     developing chess engines, or advanced players who are doing deep
;;     analysis on games.  This mode is not useful for simply playing chess.

;; Bindings

;;     No keys are bound by default.  Consider

;;         (eval-after-load "pygn-mode"
;;           (define-key pygn-mode-map (kbd "M-f") 'pygn-mode-next-move)
;;           (define-key pygn-mode-map (kbd "M-b") 'pygn-mode-previous-move))

;; Customization

;;     M-x customize-group RET pygn RET

;; See Also

;;     http://www.saremba.de/chessgml/standards/pgn/pgn-complete.htm

;;     https://github.com/dwcoates/uci-mode

;; Prior Art

;;     https://github.com/jwiegley/emacs-chess

;; Notes

;; Compatibility and Requirements

;;     GNU Emacs 26.1+, compiled with dynamic module support

;;     tree-sitter.el and tree-sitter-langs.el

;;     Python and the chess library are needed for numerous features such
;;     as SVG board images:

;;         https://pypi.org/project/chess/

;;     A version of the Python chess library is bundled with this package.
;;     Note that the chess library has its own license (GPL3+).

;;; Code:

(defconst pygn-mode-version "0.6.0")

;;; Imports

(require 'cl-lib)
(require 'comint)
(require 'uci-mode nil t)
(require 'nav-flash nil t)
(require 'ivy nil t)
(require 'tree-sitter)
(require 'tree-sitter-hl)
(require 'tree-sitter-langs)

;;; Declarations

(eval-when-compile
  (require 'subr-x)
  (defvar nav-flash-delay)
  (defvar uci-mode-engine-buffer)
  (defvar uci-mode-engine-buffer-name))

(declare-function uci-mode-engine-proc   "uci-mode.el")
(declare-function uci-mode-run-engine    "uci-mode.el")
(declare-function uci-mode-send-stop     "uci-mode.el")
(declare-function uci-mode-send-commands "uci-mode.el")

(declare-function ivy-completing-read "ivy.el")

;;; Customizable variables

;;;###autoload
(defgroup pygn nil
  "A major-mode for chess PGN files, powered by Python."
  :version pygn-mode-version
  :prefix "pygn-mode-"
  :group 'data
  :group 'games)

(defcustom pygn-mode-python-executable "python"
  "Path to a Python 3.7+ interpreter."
  :group 'pygn
  :type 'string)

(defcustom pygn-mode-pythonpath
  (expand-file-name
   "lib/python/site-packages"
   (file-name-directory
    (or load-file-name
        (bound-and-true-p byte-compile-current-file)
        (buffer-file-name (current-buffer)))))
  "A colon-delimited path to prepend to the `$PYTHONPATH' environment variable.

The default points to the bundled Python `chess' library.  Set to nil to
ignore the bundled library and use only the system `$PYTHONPATH'."
  :group 'pygn
  :type 'string)

(defcustom pygn-mode-board-size 400
  "Size for graphical board display, expressed as pixels-per-side."
  :group 'pygn
  :type 'int)

(defcustom pygn-mode-board-flipped nil
  "If non-nil, display the board flipped."
  :group 'pygn-mode
  :type 'boolean)

(defcustom pygn-mode-flash-full-game nil
  "If non-nil, flash the entire PGN on game selection actions."
  :group 'pygn
  :type 'boolean)

(defcustom pygn-mode-default-engine-depth 20
  "Default depth for engine analysis."
  :group 'pygn
  :type 'int)

(defcustom pygn-mode-default-engine-time 15
  "Default seconds for engine analysis."
  :group 'pygn
  :type 'int)

(defcustom pygn-mode-server-stderr-buffer-name nil
  "Buffer name for server stderr output, nil to redirect stderr to null device."
  :group 'pygn
  :type 'string)

;;;###autoload
(defgroup pygn-faces nil
  "Faces used by pygn-mode."
  :group 'pygn)

(defface pygn-mode-tagpair-key-face
  '((t (:inherit font-lock-keyword-face)))
  "pygn-mode face for tagpair (header) keys."
  :group 'pygn-faces)

(defface pygn-mode-tagpair-value-face
  '((t (:inherit font-lock-string-face)))
  "pygn-mode face for tagpair (header) values."
  :group 'pygn-faces)

(defface pygn-mode-tagpair-bracket-face
   '((t (:foreground "Gray50")))
  "pygn-mode face for tagpair (header) square brackets."
  :group 'pygn-faces)

(defface pygn-mode-annotation-face
  '((t (:inherit font-lock-comment-face)))
  "pygn-mode face for annotation symbols."
  :group 'pygn-faces)

(defface pygn-mode-inline-comment-face
  '((t (:inherit font-lock-comment-face)))
  "pygn-mode face for inline comments."
  :group 'pygn-faces)

(defface pygn-mode-rest-of-line-comment-face
  '((t (:inherit font-lock-comment-face)))
  "pygn-mode face for rest-of-line comments."
  :group 'pygn-faces)

(defface pygn-mode-twic-section-comment-face
  '((t (:inherit font-lock-comment-face)))
  "pygn-mode face for TWIC-style section comments."
  :group 'pygn-faces)

(defface pygn-mode-move-face
  '((t (:inherit default)))
  "pygn-mode face for moves."
  :group 'pygn-faces)

(defface pygn-mode-move-number-face
  '((t (:inherit default)))
  "pygn-mode face for move numbers."
  :group 'pygn-faces)

(defface pygn-mode-variation-move-face
  '((t (:foreground "Gray50")))
  "pygn-mode face for variation moves."
  :group 'pygn-faces)

(defface pygn-mode-variation-move-number-face
  '((t (:foreground "Gray50")))
  "pygn-mode face for variation move numbers."
  :group 'pygn-faces)

(defface pygn-mode-variation-delimiter-face
  '((t (:foreground "Gray50")))
  "pygn-mode face for variation delimiters."
  :group 'pygn-faces)

(defface pygn-mode-variation-annotation-face
  '((t (:inherit font-lock-comment-face)))
  "pygn-mode face for annotation symbols within variations."
  :group 'pygn-faces)

(defface pygn-mode-variation-inline-comment-face
  '((t (:inherit font-lock-comment-face)))
  "pygn-mode face for inline comments within variations."
  :group 'pygn-faces)

(defface pygn-mode-variation-rest-of-line-comment-face
  '((t (:inherit font-lock-comment-face)))
  "pygn-mode face for rest-of-line comments within variations."
  :group 'pygn-faces)

(defface pygn-mode-result-face
  '((t (:inherit font-lock-builtin-face)))
  "pygn-mode face for result codes."
  :group 'pygn-faces)

(defface pygn-mode-invalid-face
  '((t (:inherit font-lock-warning-face)))
  "pygn-mode face for spans of text which are not valid PGN."
  :group 'pygn-faces)

(define-obsolete-face-alias
  'pygn-mode-nag-face
  'pygn-mode-annotation-face
  "0.6.0")

;;; Variables

(defvar pygn-mode-script-directory
  (file-name-directory
   (or load-file-name
       (bound-and-true-p byte-compile-current-file)
       (buffer-file-name (current-buffer))))
  "Directory to find Python server script \"pygn_server.py\".")

(defvar pygn-mode-python-chess-succeeded nil
  "Whether a simple external command using the Python chess library has succeeded.")

(defvar pygn-mode-fen-buffer-name "*pygn-mode-fen*"
  "Buffer name used to display FENs.")

(defvar pygn-mode-board-buffer-name "*pygn-mode-board*"
  "Buffer name used to display boards.")

(defvar pygn-mode-line-buffer-name "*pygn-mode-line*"
  "Buffer name used to display SAN lines.")

(defvar pygn-mode-diagnostic-output-buffer-name "*pygn-mode-diagnostic-output*"
  "Buffer name used to display results of a diagnostic check.")

(defvar pygn-mode--server-process nil
  "Python-based server which powers many `pygn-mode' features.")

(defvar pygn-mode--server-buffer-name " *pygn-mode-server*"
  "Buffer name used to associate a server process.")

(defvar pygn-mode--server-buffer nil
  "Buffer to which the `pygn-mode' server process is associated.")

(defvar pygn-mode--server-receive-every-seconds 0.01
  "How often `pygn-mode--server-receive' should check the server for output when polling.")

(defvar pygn-mode--server-receive-max-seconds 0.5
  "The maximum amount of time `pygn-mode--server-receive' should check the server for output when polling.")

(defvar pygn-mode--strict-legal-move-pat
  "\\<\\(?:[RNBQK][a-h]?[1-8]?x?[a-h][1-8]\\|[a-h]\\(?:x[a-h]\\)?[1-8]\\(?:=[RNBQ]\\)?\\|O\\(?:-O\\)\\{1,2\\}\\)\\(?:\\+\\+?\\|#\\)?"
  "Regular expression strictly matching a legal SAN move.")

(defvar pygn-mode--relaxed-legal-move-pat
  (concat "[ \t]*[0-9]*[.…\s-]*" pygn-mode--strict-legal-move-pat)
  "Regular expression matching a legal SAN move with leading move numbers and whitespace.")

;;; Syntax table

(defvar pygn-mode-syntax-table
  (let ((st (make-syntax-table text-mode-syntax-table)))
    (with-syntax-table st
      (modify-syntax-entry ?{ "<")
      (modify-syntax-entry ?} ">")
      (modify-syntax-entry ?\n "-")
      (modify-syntax-entry ?\r "-")
      (modify-syntax-entry ?\\ "\\")
      (modify-syntax-entry ?\" "\"")
      (modify-syntax-entry ?| "w")
      (modify-syntax-entry ?+ "w")
      (modify-syntax-entry ?- "w")
      (modify-syntax-entry ?* "w")
      (modify-syntax-entry ?/ "w")
      (modify-syntax-entry ?± "w")
      (modify-syntax-entry ?– "w")
      (modify-syntax-entry ?! "w")
      (modify-syntax-entry ?? "w")
      (modify-syntax-entry ?‼ "w")
      (modify-syntax-entry ?⁇ "w")
      (modify-syntax-entry ?⁈ "w")
      (modify-syntax-entry ?⁉ "w")
      (modify-syntax-entry ?↑ "w")
      (modify-syntax-entry ?→ "w")
      (modify-syntax-entry ?⇆ "w")
      (modify-syntax-entry ?⇔ "w")
      (modify-syntax-entry ?⇗ "w")
      (modify-syntax-entry ?∆ "w")
      (modify-syntax-entry ?− "w")
      (modify-syntax-entry ?∓ "w")
      (modify-syntax-entry ?∞ "w")
      (modify-syntax-entry ?⊥ "w")
      (modify-syntax-entry ?⌓ "w")
      (modify-syntax-entry ?□ "w")
      (modify-syntax-entry ?✕ "w")
      (modify-syntax-entry ?\⟪ "w")
      (modify-syntax-entry ?\⟫ "w")
      (modify-syntax-entry ?⟳ "w")
      (modify-syntax-entry ?⨀ "w")
      (modify-syntax-entry ?⩱ "w")
      (modify-syntax-entry ?⩲ "w")
      (modify-syntax-entry ?= "w"))
    st)
  "Syntax table used while in `pygn-mode'.")

;;; Keymaps

(defvar pygn-mode-map
  (let ((map (make-sparse-keymap)))
    ;; menu bar and lighter
    (define-key map [menu-bar PyGN]
      (cons "PyGN" (make-sparse-keymap "PyGN")))
    (define-key map [menu-bar PyGN pygn-mode-select-game]
      '(menu-item "Select Game" pygn-mode-select-game
                  :help "Select the current game"))
    (define-key map [menu-bar PyGN pygn-mode-ivy-jump-to-game-by-fen]
      '(menu-item "Jump to Game by FEN" pygn-mode-ivy-jump-to-game-by-fen
                  :enable (featurep 'ivy)
                  :help "Jump to a game by FEN"))
    (define-key map [menu-bar PyGN pygn-mode-ivy-jump-to-game-by-any-header]
      '(menu-item "Jump to Game by Header" pygn-mode-ivy-jump-to-game-by-header
                  :enable (featurep 'ivy)
                  :help "Jump to a game by any header content"))
    (define-key map [menu-bar PyGN pygn-mode-previous-game]
      '(menu-item "Previous Game" pygn-mode-previous-game
                  :help "Navigate to the previous game"))
    (define-key map [menu-bar PyGN pygn-mode-next-game]
      '(menu-item "Next Game" pygn-mode-next-game
                  :help "Navigate to the next game"))
    (define-key map [menu-bar PyGN sep] menu-bar-separator)
    (define-key map [menu-bar PyGN pygn-mode-previous-move]
      '(menu-item "Previous Move" pygn-mode-previous-move
                  :help "Navigate to the previous move"))
    (define-key map [menu-bar PyGN pygn-mode-next-move]
      '(menu-item "Next Move" pygn-mode-next-move
                  :help "Navigate to the next move"))
    (define-key map [menu-bar PyGN sep-2] menu-bar-separator)
    (define-key map [menu-bar PyGN pygn-mode-engine-go-time]
      '(menu-item "Go Time at Point" pygn-mode-engine-go-time
                  :enable (featurep 'uci-mode)
                  :help "UCI Engine \"go time\" at point in separate window"))
    (define-key map [menu-bar PyGN pygn-mode-engine-go-depth]
      '(menu-item "Go Depth at Point" pygn-mode-engine-go-depth
                  :enable (featurep 'uci-mode)
                  :help "UCI Engine \"go depth\" at point in separate window"))
    (define-key map [menu-bar PyGN pygn-mode-display-fen-at-pos]
      '(menu-item "FEN at Point" pygn-mode-display-fen-at-pos
                  :help "Display FEN at point in separate window"))
    (define-key map [menu-bar PyGN pygn-mode-display-board-at-pos]
      '(menu-item "Board at Point" pygn-mode-display-board-at-pos
                  :help "Display board at point in separate window"))
    (define-key map [menu-bar PyGN pygn-mode-display-variation-line-at-pos]
      '(menu-item "Line at Point" pygn-mode-display-variation-line-at-pos
                  :help "Display SAN line at point in separate window"))

    ;; mouse
    (define-key map [mouse-2] 'pygn-mode-mouse-display-variation-board)

    ;; example keystrokes:
    ;;
    ;; (define-key map (kbd "C-c C-n") 'pygn-mode-next-game)
    ;; (define-key map (kbd "C-c C-p") 'pygn-mode-previous-game)
    ;; (define-key map (kbd "M-f")     'pygn-mode-next-move)
    ;; (define-key map (kbd "M-b")     'pygn-mode-previous-move)
    ;;
    ;; and note that `down-list'/`backward-up-list' already works to
    ;; enter/exit a parenthesized variation
    map)
  "Keymap for `pygn-mode'.")

;;; Utility functions

(defun pygn-mode--get-or-create-board-buffer ()
  "Get or create the `pygn-mode' board buffer."
  (let ((buf (get-buffer-create pygn-mode-board-buffer-name)))
    (with-current-buffer buf
      (unless (eq 'pygn-board-mode major-mode)
        (pygn-board-mode)))
    buf))

(defun pygn-mode--opts-to-argparse (opt-plist)
  "Convert OPT-PLIST into an options string consumable by Python's argparse.

To produce a flag which takes no options, give a plist value of t."
  (let ((key-string nil)
        (argparse-string ""))
    (cl-loop for (key value) on opt-plist by (function cddr)
             do (progn
                  (setq key-string
                        (replace-regexp-in-string
                         "^:" "-" (symbol-name key)))
                  (cond
                   ((eq value t)
                    (setq argparse-string (concat
                                           argparse-string
                                           " " key-string)))
                   ;; if option is nil then we just don't send the flag.
                   ((not (eq value nil))
                    (let ((val-string (shell-quote-argument
                                       (format "%s" value))))
                      (setq argparse-string (concat
                                             argparse-string
                                             (format " %s=%s" key-string val-string))))))))
    argparse-string))

(defun pygn-mode--set-python-path ()
  "Prepend `pygn-mode-pythonpath' to the system `$PYTHONPATH'."
  (setenv "PYTHONPATH" (concat pygn-mode-pythonpath ":" (getenv "PYTHONPATH"))))

(defun pygn-mode--server-running-p ()
  "Return non-nil iff `pygn-mode--server-process' is running."
  (and pygn-mode--server-process (process-live-p pygn-mode--server-process)))

(defun pygn-mode--python-chess-guard ()
  "Throw an error unless the Python chess library is available."
  (unless pygn-mode-python-chess-succeeded
    (let ((process-environment (cl-copy-list process-environment)))
      (when pygn-mode-pythonpath
        (pygn-mode--set-python-path))
      (if (zerop (call-process pygn-mode-python-executable nil nil nil "-c" "import chess"))
          (setq pygn-mode-python-chess-succeeded t)
        (error "The Python interpreter at `pygn-mode-python-path' must have the Python chess library available")))))

(defun pygn-mode--get-stderr-buffer ()
  "Get or create the buffer to which to redirect the standard error."
  (when pygn-mode-server-stderr-buffer-name
    (get-buffer-create pygn-mode-server-stderr-buffer-name)))

(defun pygn-mode--server-start (&optional force)
  "Initialize `pygn-mode--server-process'.

Optionally FORCE recreation if the server already exists."
  (pygn-mode--python-chess-guard)
  (if force
      (pygn-mode--server-kill)
    (when (pygn-mode--server-running-p)
      (error "The pygn-mode server process is already running.  Use optional `force' to recreate")))
  (message "Initializing pygn-mode server process%s." (if force " (forcing)" ""))
  (let ((process-environment (cl-copy-list process-environment)))
    (when pygn-mode-pythonpath
      (pygn-mode--set-python-path))
    (setenv "PYTHONIOENCODING" "UTF-8")
    (setq pygn-mode--server-buffer (get-buffer-create pygn-mode--server-buffer-name))
    (setq pygn-mode--server-process
          (make-process :name "pygn-mode-server"
                        :buffer pygn-mode--server-buffer
                        :noquery t
                        :sentinel #'ignore
                        :coding 'utf-8
                        :connection-type 'pipe
                        :stderr (or (pygn-mode--get-stderr-buffer) null-device)
                        :command (list pygn-mode-python-executable
                                       "-u"
                                       (expand-file-name "pygn_server.py" pygn-mode-script-directory)
                                       "-"))))
  (unless (string-match-p (regexp-quote  "Server started.") (pygn-mode--server-receive))
    (error "Server for `pygn-mode' failed to start.  Try running `pygn-mode-run-diagnostic'")))

(defun pygn-mode--server-kill ()
  "Stop the currently running `pygn-mode--server-process'."
  (when (pygn-mode--server-running-p)
    (process-send-eof pygn-mode--server-process)
    (delete-process pygn-mode--server-process)
    (setq pygn-mode--server-process nil)
    (message "pygn-mode server process killed.")))

(cl-defun pygn-mode--server-send (&key command options payload-type payload)
  "Send a message to the running `pygn-mode--server-process'.

The server request format is documented more completely at doc/server.md
in the source distribution for `pygn-mode'.

:COMMAND should be a symbol such as :pgn-to-fen, which is a command
known by the server.  :OPTIONS should be a plist such as (:pixels 400)
in which the keys correspond to argparse arguments known by the server.
:PAYLOAD-TYPE should be a symbol such as :pgn, identifying the type of the
data payload, and :PAYLOAD may contain arbitrary data."
  (unless (pygn-mode--server-running-p)
    (error "The pygn-mode server is not running -- cannot send a message"))
  (setq payload (replace-regexp-in-string "\n" "\\\\n" payload))
  (setq payload (replace-regexp-in-string "[\n\r]*$" "\n" payload))
  (process-send-string
   pygn-mode--server-process
   (mapconcat #'identity
              (list
               (symbol-name :version)
               pygn-mode-version
               (symbol-name command)
               (pygn-mode--opts-to-argparse options)
               "--"
               (symbol-name payload-type)
               payload)
              " ")))

(defun pygn-mode--server-receive ()
  "Receive a response after `pygn-mode--server-send'.

Respects the variables `pygn-mode--server-receive-every-seconds' and
`pygn-mode--server-receive-max-seconds'."
  (unless (pygn-mode--server-running-p)
    (error "The pygn-mode server is not running -- cannot receive a response"))
  (unless (get-buffer pygn-mode--server-buffer)
    (error "The pygn-mode server output buffer does not exist -- cannot receive a response"))
  (with-current-buffer pygn-mode--server-buffer
    (let ((tries 0)
          (server-message nil))
      (goto-char (point-min))
      (while (and (not (eq ?\n (char-before (point-max))))
                  (< (* tries pygn-mode--server-receive-every-seconds) pygn-mode--server-receive-max-seconds))
        (accept-process-output pygn-mode--server-process pygn-mode--server-receive-every-seconds nil 1)
        (cl-incf tries))
      (setq server-message (buffer-substring-no-properties (point-min) (point-max)))
      (erase-buffer)
      server-message)))

(cl-defun pygn-mode--server-query (&key command options payload-type payload)
  "Send a request to `pygn-mode--server-process', wait, and return response.

:COMMAND, :OPTIONS, :PAYLOAD-TYPE, and :PAYLOAD are as documented at
`pygn-mode--server-send'."
  (unless (pygn-mode--server-running-p)
    (pygn-mode--server-start))
  (pygn-mode--server-send
   :command      command
   :options      options
   :payload-type payload-type
   :payload      payload)
  (pygn-mode--server-receive))

;; it is a bit muddy that the parser is permitted to restart the server
(defun pygn-mode--parse-response (response)
  "Parse RESPONSE string into a list of payload-id and payload.

Restart `pygn-mode--server-process' if the response version string does
not match the client."
  (let ((response-version nil))
    (save-match-data
      (setq response (replace-regexp-in-string "\n+\\'" "" response))
      (when (string= "" response)
        (error "Bad response from `pygn-mode' server -- empty response"))
      (unless (string-match
               "\\`:version\\s-+\\(\\S-+\\)\\s-+\\(.*\\)" response)
        (pygn-mode--server-start 'force)
        (error "Bad response from `pygn-mode' server -- no :version.  Attempted restart"))
      (setq response-version (match-string 1 response))
      (setq response (match-string 2 response))
      (unless (equal response-version pygn-mode-version)
        (pygn-mode--server-start 'force)
        (error "Bad response from `pygn-mode' server -- unexpected :version value: '%s'.  Attempted restart" response-version))
      (unless (string-match
               "\\`\\(:\\S-+\\)\\(.*\\)" response)
        (error "Bad response from `pygn-mode' server"))
      (list
       (intern (match-string 1 response))
       (replace-regexp-in-string
        "\\`\s-*" "" (match-string 2 response))))))

;; would be nicer if multi-type were chosen by how far up we must go in the
;; syntax tree to find a node of the type, instead of the latest-starting by
;; buffer position.
(cl-defun pygn-mode--true-containing-node (&optional type pos)
  "Return the node of type TYPE which contains POS, adjusting whitespace.

TYPE defaults to the nearest containing node.  If TYPE is a symbol, find
the first containing node of that type.  If TYPE is a list of symbols,
find the latest-starting containing node of any of the given types.

POS defaults to the point.

If a node has leading or trailing whitespace, and POS is in that
whitespace, ignore the result, and consult the parent node.

Also respect narrowing.

If TYPE is unset, and an appropriate containing node is not
found, return the root node."
  (cl-callf or pos (point))
  (save-excursion
    (goto-char pos)
    (let ((best-first -1)
          (best-node nil))
      (dolist (tp (if (listp type) (or type '(nil)) (list type)))
        (let ((node (tree-sitter-node-at-point tp))
              (first nil)
              (last nil))
          (while node
            (setq first (pygn-mode--true-node-first-position node))
            (setq last (pygn-mode--true-node-last-position node))
            (cond
              ((and (>= pos first)
                    (<= pos last)
                    (> first best-first))
               (setq best-first first)
               (setq best-node node)
               (setq node nil))
              (tp
               (setq node nil))
              (t
               (setq node (tsc-get-parent node)))))))
      (if best-node
          best-node
        (unless type
          (tsc-root-node tree-sitter-tree))))))

(defun pygn-mode--true-node-first-position (node)
  "Return the true first position within NODE, adjusting whitespace.

Also respect narrowing."
  (let ((first (max (point-min) (tsc-node-start-position node))))
    (cond
      ((eq node (tsc-root-node tree-sitter-tree))
       (setq first (point-min)))
      (t
       (save-excursion
         (goto-char first)
         (skip-syntax-forward "-")
         (setq first (point)))))
    first))

(defun pygn-mode--true-node-last-position (node)
  "Return the true last position within NODE, adjusting whitespace.

Also respect narrowing."
  (let ((last (min (point-max) (tsc-node-end-position node))))
    (cond
      ((eq node (tsc-root-node tree-sitter-tree))
       (setq last (point-max)))
      (t
       (save-excursion
         (goto-char last)
         (skip-syntax-backward "-")
         (while (and (> (point) (point-min))
                     (looking-at-p "\\s-"))
           (forward-char -1))
         (setq last (point)))))
    last))

(defun pygn-mode--true-node-after-position (node)
  "Return the true first position after NODE, adjusting whitespace.

Also respect narrowing."
  (let ((last (pygn-mode--true-node-last-position node)))
    (min (point-max) (1+ last))))

(defun pygn-mode-inside-comment-p (&optional pos)
  "Whether POS is inside a PGN comment.

POS defaults to the point."
  (nth 4 (save-excursion (syntax-ppss pos))))

(defun pygn-mode-inside-escaped-line-p (&optional pos)
  "Whether POS is inside a PGN line-comment.

POS defaults to the point."
  (save-excursion
    (goto-char (or pos (point)))
    (and (nth 4 (syntax-ppss pos))
         (eq ?\% (char-after (line-beginning-position))))))

(defun pygn-mode-inside-variation-p (&optional pos)
  "Whether POS is inside a PGN variation.

POS defaults to the point."
  (when-let ((variation-node (pygn-mode--true-containing-node 'variation pos)))
    variation-node))

(defun pygn-mode-inside-variation-or-comment-p (&optional pos)
  "Whether POS is inside a PGN comment or a variation.

POS defaults to the point."
  (or (pygn-mode-inside-comment-p pos)
      (pygn-mode-inside-variation-p pos)))

(defun pygn-mode-inside-header-p (&optional pos)
  "Whether POS is inside a PGN header.

POS defaults to the point."
  (when-let ((header-node (pygn-mode--true-containing-node 'header pos)))
    header-node))

;; Unlike some other defuns, the node returned here does not represent the
;; separator, because the separator is whitespace, and there is no such node.
(defun pygn-mode-inside-separator-p (&optional pos)
  "Whether POS is inside a PGN separator.

Separators are empty lines after tagpair headers or after games.

POS defaults to the point."
  (when-let ((node (pygn-mode--true-containing-node nil pos))
             (type (tsc-node-type node)))
    (when (and (memq type '(game series_of_games))
               (not (tree-sitter-node-at-point 'result_code)))
      node)))

(defun pygn-mode-looking-at-result-code ()
  "Whether the point is looking at a PGN movetext result code."
  (looking-at-p "\\(?:1-0\\|0-1\\|1/2-1/2\\|\\*\\)\\s-*$"))

(defun pygn-mode-looking-at-suffix-annotation ()
  "Whether the point is looking at a SAN suffix annotation."
  (looking-at-p "\\(?:‼\\|⁇\\|⁈\\|⁉\\|!\\|\\?\\|!!\\|!\\?\\|\\?!\\|\\?\\?\\)\\>"))

(defun pygn-mode-looking-at-relaxed-legal-move ()
  "Whether the point is looking at a legal SAN chess move.

Leading move numbers, punctuation, and spaces are allowed, and ignored."
  (let ((inhibit-changing-match-data t))
    (and (looking-at-p pygn-mode--relaxed-legal-move-pat)
         (not (looking-back "[a-h]" 1)))))

(defun pygn-mode-looking-at-strict-legal-move ()
  "Whether the point is looking at a legal SAN chess move.

\"Strict\" means that leading move numbers, punctuation, and spaces are
not allowed on the SAN move."
  (let ((inhibit-changing-match-data t))
    (and (looking-at-p pygn-mode--strict-legal-move-pat)
         (not (looking-back "[a-h]" 1)))))

(defun pygn-mode-looking-back-strict-legal-move ()
  "Whether the point is looking back at a legal SAN chess move.

\"Strict\" means that leading move numbers, punctuation, and spaces are
not examined on the SAN move."
  (and (or (looking-at-p "\\s-")
           (pygn-mode-looking-at-suffix-annotation))
       (save-excursion
         (forward-word-strictly -1)
         (pygn-mode-looking-at-strict-legal-move))))

(defun pygn-mode-game-start-position (&optional pos)
  "Start position for the PGN game which contains position POS.

If POS is not within a game, returns nil.

POS defaults to the point."
  (when-let ((game-node (pygn-mode--true-containing-node 'game pos)))
    (pygn-mode--true-node-first-position game-node)))

(defun pygn-mode-game-end-position (&optional pos)
  "End position for the PGN game which contains position POS.

If POS is not within a game, returns nil.

POS defaults to the point."
  (when-let ((game-node (pygn-mode--true-containing-node 'game pos)))
    (pygn-mode--true-node-after-position game-node)))

;; todo maybe shouldn't consult looking-back here, but it works well for the
;; purpose of pygn-mode-previous-move
(defun pygn-mode-backward-exit-variations-and-comments ()
  "However deep in nested variations and comments, exit and skip backward."
  (save-match-data
    (while (or (> (nth 0 (syntax-ppss)) 0)
               (nth 4 (syntax-ppss))
               (looking-back ")\\s-*" 10)
               (looking-back "}\\s-*" 10))
      (cond
        ((> (nth 0 (syntax-ppss)) 0)
         (up-list (- (nth 0 (syntax-ppss)))))
        ((nth 4 (syntax-ppss))
         (skip-syntax-backward "^<")
         (backward-char 1))
        ((looking-back ")\\s-*" 10)
         (skip-syntax-backward "-")
         (backward-char 1))
        ((looking-back "}\\s-*" 10)
         (skip-syntax-backward "-")
         (backward-char 1)))
      (skip-syntax-backward "-")
      (when (looking-at-p "^")
        (forward-line -1)
        (goto-char (line-end-position))
        (skip-syntax-backward "-")))))

(defun pygn-mode-pgn-at-pos (pos)
  "Return a single-game PGN string inclusive of any move at POS."
  (save-match-data
    (save-excursion
      (goto-char pos)
      (cond
        ((pygn-mode-inside-header-p)
         (unless (= pos (line-end-position))
           (goto-char (line-beginning-position))
           (when (looking-at-p "\\[Event ")
             (forward-line 1))))
        ((pygn-mode-inside-separator-p)
         t)
        ((pygn-mode-inside-variation-or-comment-p)
         ;; crudely truncate at pos
         ;; and depend on Python chess library to clean up trailing garbage
         t)
        ((pygn-mode-looking-at-result-code)
         t)
        ((pygn-mode-looking-back-strict-legal-move)
         t)
        ((looking-back "[)}]" 1)
         t)
        ((pygn-mode-looking-at-relaxed-legal-move)
         (re-search-forward pygn-mode--relaxed-legal-move-pat nil t))
        ;; todo both of these might be arguable. shake this out in ert testing.
        ((or (looking-at-p "^")
             (looking-back "[\s-]" 1))
         t)
        (t
         ;; this fallback logic is probably too subtle because it sometimes rests
         ;; on the previous word, and sometimes successfully searches forward.
         ;; todo continue making the conditions more explicit and descriptiive
         (let ((word-bound (save-excursion (forward-word-strictly 1) (point)))
               (game-bound (pygn-mode-game-end-position)))
           (forward-word-strictly -1)
           (re-search-forward pygn-mode--relaxed-legal-move-pat
                              (min word-bound game-bound)
                              t))))
      (buffer-substring-no-properties
       (pygn-mode-game-start-position)
       (point)))))

(defun pygn-mode-pgn-at-pos-as-if-variation (pos)
  "Return a single-game PGN string as if a variation had been played.

Inclusive of any move at POS.

Does not work for nested variations."
  (if (not (pygn-mode-inside-variation-p pos))
      (pygn-mode-pgn-at-pos pos)
    ;; else
    (save-excursion
      (save-match-data
        (goto-char pos)
        (cond
          ((looking-at-p "\\s-*)")
           ;; crudely truncate at pos
           ;; and depend on Python chess library to clean up trailing garbage
           t)
          ((pygn-mode-inside-comment-p)
           ;; crudely truncate at pos
           ;; and depend on Python chess library to clean up trailing garbage
           t)
          ((pygn-mode-looking-back-strict-legal-move)
           t)
          ((pygn-mode-looking-at-relaxed-legal-move)
           (re-search-forward pygn-mode--relaxed-legal-move-pat nil t))
          (t
           ;; this fallback logic is probably too subtle because it sometimes rests
           ;; on the previous word, and sometimes successfully searches forward.
           ;; todo continue making the conditions more explicit and descriptive
           (let ((word-bound (save-excursion (forward-word-strictly 1) (point)))
                 (sexp-bound (save-excursion (up-list 1) (1- (point)))))
             (forward-word-strictly -1)
             (re-search-forward pygn-mode--relaxed-legal-move-pat
                                (min word-bound sexp-bound)
                                t))))
        (let ((pgn (buffer-substring-no-properties
                    (pygn-mode-game-start-position)
                    (point))))
          (with-temp-buffer
            (insert pgn)
            (when (pygn-mode-inside-variation-p)
              (up-list -1)
              (delete-char 1)
              (delete-region
               (save-excursion (pygn-mode-backward-exit-variations-and-comments) (point))
               (point))
              (delete-region
               (save-excursion (forward-word-strictly -1) (point))
               (point)))
            (goto-char (point-max))
            (buffer-substring-no-properties (point-min) (point-max))))))))

(defun pygn-mode-pgn-to-fen (pgn)
  "Return the FEN corresponding to the position after PGN."
  (let ((response (pygn-mode--server-query
                   :command      :pgn-to-fen
                   :payload-type :pgn
                   :payload      pgn)))
    (cl-callf pygn-mode--parse-response response)
    (unless (eq :fen (car response))
      (error "Bad response from `pygn-mode' server"))
    (cadr response)))

(defun pygn-mode-pgn-to-board (pgn format)
  "Return a board representation for the position after PGN.

FORMAT may be either 'svg or 'text."
  (let ((response (pygn-mode--server-query
                   :command      :pgn-to-board
                   :options      `(:pixels       ,pygn-mode-board-size
                                   :board_format ,format
                                   :flipped      ,pygn-mode-board-flipped)
                   :payload-type :pgn
                   :payload      pgn)))
    (cl-callf pygn-mode--parse-response response)
    (unless (memq (car response) '(:board-svg :board-text))
      (error "Bad response from `pygn-mode' server"))
    (cadr response)))

(defun pygn-mode-pgn-to-line (pgn)
  "Return the SAN line corresponding to the position after PGN."
  (let ((response (pygn-mode--server-query
                   :command      :pgn-to-mainline
                   :payload-type :pgn
                   :payload      pgn)))
    (cl-callf pygn-mode--parse-response response)
    (unless (eq :san (car response))
      (error "Bad response from `pygn-mode' server"))
    (cadr response)))

(defun pygn-mode-focus-game-at-point ()
  "Recenter the window and highlight the current game at point."
  (recenter-window-group)
  (when (fboundp 'nav-flash-show)
    (let ((nav-flash-delay 0.2)
          (beg (if pygn-mode-flash-full-game
                   (pygn-mode-game-start-position)
                 nil))
          (end (if pygn-mode-flash-full-game
                   (pygn-mode-game-end-position)
                 nil)))
      (nav-flash-show beg end))))

(defun pygn-mode-all-header-coordinates ()
  "Find PGN headers for all games in the buffer.

Returns an alist of cells in the form (CONTENT . POS), where CONTENT contains
strings from header tagpairs of games, and POS is the starting position of a
game in the buffer.

For use in `pygn-mode-ivy-jump-to-game-by-any-header'."
  (let ((game-starts nil)
        (game-bounds nil)
        (header-coordinates nil)
        (element nil))
    (save-excursion
      (save-restriction
        (goto-char (point-min))
        (while (re-search-forward "^\\[Event " nil t)
          (push (line-beginning-position) game-starts))
        (setq game-starts (nreverse game-starts))
        (while (setq element (pop game-starts))
          (push (cons element (1- (or (car game-starts) (point-max)))) game-bounds))
        (setq game-bounds (nreverse game-bounds))
        (cl-loop for cell in game-bounds
              do (progn
                   (narrow-to-region (car cell) (cdr cell))
                   (goto-char (point-min))
                   (re-search-forward "\n[ \t\r]*\n" nil t)
                   (push (cons
                          (replace-regexp-in-string
                           "\\`\\s-+" ""
                           (replace-regexp-in-string
                            "\n" " "
                            (replace-regexp-in-string
                             "^\\[\\S-+\\s-+\"[?.]*\"\\]" ""
                             (buffer-substring-no-properties (car cell) (point)))))
                          (car cell))
                         header-coordinates)))
        (nreverse header-coordinates)))))

(defun pygn-mode-fen-coordinates ()
  "Find PGN FEN headers for all games in the buffer.

Returns an alist of cells in the form (CONTENT . POS), where CONTENT contains
strings from FEN header tagpairs of games, and POS is the starting position
of a game in the buffer.

For use in `pygn-mode-ivy-jump-to-game-by-fen'."
  (let ((all-coordinates (pygn-mode-all-header-coordinates))
        (fen-coordinates nil)
        (fen nil))
    (cl-loop for cell in (cl-remove-if-not
                          (lambda (x) (cl-search "[FEN " (car x)))
                          all-coordinates)
             do (progn
                  (setq fen
                        (replace-regexp-in-string
                         "\\`.*?\\[FEN\\s-+\"\\(.*?\\)\".*" "\\1"
                         (car cell)))
                  (push (cons fen (cdr cell)) fen-coordinates)))
    (nreverse fen-coordinates)))

;;; Font-lock

(defvar pygn-mode-tree-sitter-patterns
  [
   (tagpair_delimiter_open) @tagpair-bracket
   (tagpair_delimiter_close) @tagpair-bracket
   (tagpair_key) @tagpair-key
   (tagpair tagpair_value_delimiter: (double_quote) @tagpair-value)
   (tagpair_value_contents) @tagpair-value

   (variation_delimiter_open) @variation-delimiter
   (variation_delimiter_close) @variation-delimiter
   (variation_movetext variation_move_number: (move_number) @variation-move-number)
   (variation_movetext variation_san_move: (san_move) @variation-move)
   (variation_movetext variation_annotation: (annotation) @variation-annotation)
   (variation_movetext variation_comment: (inline_comment) @variation-inline-comment)
   (variation_movetext variation_comment: (rest_of_line_comment) @variation-rest-of-line-comment)

   (inline_comment) @inline-comment
   (rest_of_line_comment) @rest-of-line-comment
   (old_style_twic_section_comment) @twic-section-comment

   (movetext (move_number) @move-number)
   (movetext (san_move) @move)

   (annotation) @annotation

   (result_code) @result

   (ERROR) @invalid
   ]
  "A tree-sitter \"query\" which defines syntax highlighting for pygn-mode.")

(defun pygn-mode--capture-face-mapper (capture-name)
  "Return the default face used to highlight CAPTURE-NAME."
  (intern (format "pygn-mode-%s-face" capture-name)))

;;; Major-mode definition

;;;###autoload
(define-derived-mode pygn-mode fundamental-mode "PyGN"
  "A major-mode for chess PGN files, powered by Python."
  :syntax-table pygn-mode-syntax-table
  :group 'pygn

  ;; https://github.com/ubolonton/emacs-tree-sitter/issues/84
  (unless font-lock-defaults
    (setq font-lock-defaults '(nil)))
  (setq-local tree-sitter-hl-default-patterns pygn-mode-tree-sitter-patterns)
  (setq-local tree-sitter-hl-face-mapping-function #'pygn-mode--capture-face-mapper)

  (setq-local comment-start "{")
  (setq-local comment-end "}")
  (setq-local comment-continue " ")
  (setq-local comment-multi-line t)
  (setq-local comment-style 'plain)
  (setq-local comment-use-syntax t)
  (setq-local parse-sexp-lookup-properties t)
  (setq-local parse-sexp-ignore-comments t)

  (tree-sitter-hl-mode)

  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (default-value 'mode-line-major-mode-keymap))
    (define-key map (kbd "<mode-line> <mouse-4>")    'pygn-mode-previous-move)
    (define-key map (kbd "<mode-line> <mouse-5>")    'pygn-mode-next-move)
    (define-key map (kbd "<mode-line> <wheel-up>")   'pygn-mode-previous-move)
    (define-key map (kbd "<mode-line> <wheel-down>") 'pygn-mode-next-move)
    (setq-local mode-line-major-mode-keymap map)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.[pP][gG][nN]\\'" . pygn-mode))

;;;###autoload
(define-derived-mode pygn-board-mode special-mode "PyGN Board"
  "A major-mode for displaying chess boards."
  :group 'pygn
  :abbrev-table nil
  :syntax-table nil)

;;; Minor-mode definition

(define-minor-mode pygn-mode-follow-minor-mode
  "Minor mode for `pygn-mode'.

With a prefix argument ARG, enable mode if ARG is positive, and disable it
otherwise.  If called from Lisp, enable mode if ARG is omitted or nil.

When turned on, cursor motion in a PyGN buffer causes automatic display of
a board representation corresponding to the point.  The displayed board
will respect variations."
  :group 'pygn
  :init-value nil
  :lighter " fol"
  (if pygn-mode-follow-minor-mode
      (progn
        (pygn-mode-follow-mode-post-command-hook)
        (add-hook 'post-command-hook #'pygn-mode-follow-mode-post-command-hook nil t))
    (remove-hook 'post-command-hook #'pygn-mode-follow-mode-post-command-hook t)
    (when (get-buffer pygn-mode-board-buffer-name)
      (let ((win (get-buffer-window (get-buffer pygn-mode-board-buffer-name))))
        (when (window-live-p win)
          (delete-window win))))))

(defun pygn-mode-follow-mode-post-command-hook ()
  "Driver for function `pygn-mode-follow-minor-mode'.

Intended for use in `post-command-hook'."
  (pygn-mode-display-variation-board-at-pos (point)))

(defun pygn-mode--next-game-driver (arg)
  "Move point to next game, moving ARG games forward (backwards if negative).

Focus the game after motion."
  (save-match-data
    (let ((next-game (and (re-search-forward "^\\[Event " nil t arg)
                          (goto-char (line-beginning-position)))))
      (unless next-game
        (error "No next game")))
    (pygn-mode-focus-game-at-point)))

(cl-defun pygn-mode--run-diagnostic ()
  "Open a buffer containing a `pygn-mode' dependency/configuration diagnostic."
  (let ((buf (get-buffer-create pygn-mode-diagnostic-output-buffer-name))
        (process-environment (cl-copy-list process-environment)))
    (with-current-buffer buf
      (erase-buffer)
      (when pygn-mode-pythonpath
        (pygn-mode--set-python-path))
      (if (zerop (call-process pygn-mode-python-executable nil nil nil "-c" "pass"))
          (insert (format "[x] Good. We can execute the pygn-mode-python-executable at '%s'\n\n" pygn-mode-python-executable))
        ;; else
        (insert
         (format
          "[ ] Bad. We cannot execute the interpreter '%s'.  Try installing Python 3.7+ and/or customizing the value of pygn-mode-python-executable.\n\n"
          pygn-mode-python-executable))
        (cl-return-from pygn-mode--run-diagnostic nil))
      (if (zerop (call-process pygn-mode-python-executable nil nil nil "-c" "import sys; exit(0 if sys.hexversion >= 0x3000000 else 1)"))
          (insert (format "[x] Good. The pygn-mode-python-executable at '%s' is a Python 3 interpreter.\n\n" pygn-mode-python-executable))
        ;; else
        (insert
         (format
          "[ ] Bad. The executable '%s' is not a Python 3 interpreter.  Try installing Python 3.7+ and/or customizing the value of pygn-mode-python-executable.\n\n"
          pygn-mode-python-executable))
        (cl-return-from pygn-mode--run-diagnostic nil))
      (if (zerop (call-process pygn-mode-python-executable nil nil nil "-c" "import sys; exit(0 if sys.hexversion >= 0x3070000 else 1)"))
          (insert (format "[x] Good. The pygn-mode-python-executable at '%s' is better than or equal to Python version 3.7.\n\n" pygn-mode-python-executable))
        ;; else
        (insert
         (format
          "[ ] Bad. The executable '%s' is not at least Python version 3.7.  Try installing Python 3.7+ and/or customizing the value of pygn-mode-python-executable.\n\n"
          pygn-mode-python-executable))
        (cl-return-from pygn-mode--run-diagnostic nil))
      (if (zerop (call-process pygn-mode-python-executable nil nil nil "-c" "import chess"))
          (insert (format "[x] Good. The pygn-mode-python-executable at '%s' can import the Python chess library.\n\n" pygn-mode-python-executable))
        ;; else
        (insert
         (format
          "[ ] Bad. The executable '%s' cannot import the Python chess library.  Try installing chess, and/or customizing the value of pygn-mode-pythonpath.\n\n"
          pygn-mode-python-executable))
        (cl-return-from pygn-mode--run-diagnostic nil))
      (let ((server-script-path (expand-file-name "pygn_server.py" pygn-mode-script-directory)))
        (if (and (file-exists-p server-script-path)
                 (zerop (call-process pygn-mode-python-executable  nil nil nil server-script-path "-version")))
           (insert (format "[x] Good. The pygn-mode-script-directory ('%s') is found and the server script is callable.\n\n" pygn-mode-script-directory))
         (insert
          (format
           "[ ] Bad. The pygn-mode-script-directory ('%s') is bad or does not contain working server script (pygn_server.py).\n\n" pygn-mode-script-directory))
         (cl-return-from pygn-mode--run-diagnostic nil)))
      (dolist (melpa-lib '(uci-mode nav-flash ivy))
        (if (featurep melpa-lib)
            (insert (format "[x] Good.  The `%s' library is available.\n\n" melpa-lib))
          ;; else
          (insert
           (format
            "[ ] Bad but not a requirement.  The `%s' library is not available.  Try installing it from MELPA.\n\n" melpa-lib))))
      (insert (format "------------------------------------\n\n"))
      (insert (format "All pygn-mode required diagnostics completed successfully.\n"))))
  (cl-return-from pygn-mode--run-diagnostic t))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Interactive commands ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun pygn-mode-run-diagnostic (&optional as-command)
  "Run a dependency/configuration diagnostic for `pygn-mode'.

When called as an interactive command (when AS-COMMAND is non-nil), display
a buffer with diagnostic details.

When called noninteractively, the return value is non-nil iff required
diagnostic tests were successful."
  (interactive "p")
  (if as-command
      (progn
        (pygn-mode--run-diagnostic)
        (display-buffer (get-buffer pygn-mode-diagnostic-output-buffer-name) '(display-buffer-reuse-window)))
    ;; else
    (if (pygn-mode--run-diagnostic)
        (or (message "pygn-mode diagnostics passed.") t)
      (message "WARN: pygn-mode diagnostics failed (see '%s' buffer for details)"
               pygn-mode-diagnostic-output-buffer-name)
      nil)))

(defun pygn-mode-next-game (arg)
  "Advance to the next game in a multi-game PGN buffer.

With numeric prefix ARG, advance ARG games."
  (interactive "p")
  (cl-callf or arg 1)
  (when (looking-at-p "\\[Event ")
    (goto-char (line-end-position)))
  (pygn-mode--next-game-driver arg))

(defun pygn-mode-previous-game (arg)
  "Move back to the previous game in a multi-game PGN buffer.

With numeric prefix ARG, move back ARG games."
  (interactive "p")
  (cl-callf or arg 1)
  (save-match-data
    (unless (looking-at-p "\\[Event ")
      (re-search-backward "^\\[Event " nil t))
    (pygn-mode--next-game-driver (* arg -1))))

;; when tree-sitter-node-at-point is used instead of pygn-mode--true-containing-node
;; here, that is intentional, for two related reasons: tree-sitter-node-at-point
;; will return a leaf node even on whitespace, and we plan to call
;; tsc-get-next-sibling-node on the return value.
(defun pygn-mode-next-move (arg)
  "Advance to the next player move in a PGN game.

Treats move numbers purely as punctuation.  If the point is on a move
number, it is considered to be on the move followed by that move number.
But the advancing motion will skip over move numbers when possible.

With numeric prefix ARG, advance ARG moves forward."
  (interactive "p")
  (cl-callf or arg 1)
  (save-restriction
    (when (eq 'series_of_games (tsc-node-type (pygn-mode--true-containing-node)))
      (let ((newpos (save-excursion
                      (skip-syntax-forward "-")
                      (point))))
        (when (pygn-mode--true-containing-node 'game newpos)
          (goto-char newpos))))
    (narrow-to-region (or (pygn-mode-game-start-position) (point))
                      (or (pygn-mode-game-end-position) (point)))
    (when-let ((game-node (pygn-mode--true-containing-node 'game))
               (movetext-or-result-node (tsc-get-nth-child game-node 1))
               (movetext-or-result-start (pygn-mode--true-node-first-position movetext-or-result-node)))
      (when (< (point) movetext-or-result-start)
        (goto-char movetext-or-result-start)))
    (unless (pygn-mode--true-containing-node 'movetext)
      (error "No more moves"))
    (dotimes (_ arg)
      (let ((node (tree-sitter-node-at-point))
            (thumb (point)))
        (when-let ((move-node (pygn-mode--true-containing-node '(san_move lan_move))))
          (goto-char (pygn-mode--true-node-after-position move-node)))
        (while (not (pygn-mode--true-containing-node '(san_move lan_move)))
          (setq node (tree-sitter-node-at-point))
          (cond
            ((>= (pygn-mode--true-node-last-position node)
                 (point-max))
             (goto-char thumb)
             (error "No more moves"))
            ((pygn-mode--true-containing-node
              '(variation inline_comment rest_of_line_comment))
             (goto-char (pygn-mode--true-node-after-position
                         (pygn-mode--true-containing-node
                          '(variation inline_comment rest_of_line_comment)))))
            ((looking-at-p "\\s-")
             (skip-syntax-forward "-"))
            (t
             (setq node (tsc-get-next-sibling node))
             (if node
                 (goto-char (pygn-mode--true-node-first-position node))
               (forward-char 1)))))
        (skip-syntax-forward "-")))))

(defun pygn-mode-previous-move (arg)
  "Move back to the previous player move in a PGN game.

Treats move numbers purely as punctuation.  If the point is on a move
number, it is considered to be on the move followed by that move number.
But the backward motion will skip over move numbers when possible.

With numeric prefix ARG, move ARG moves backward."
  (interactive "p")
  (cl-callf or arg 1)
  (save-restriction
    (save-match-data
      (narrow-to-region (pygn-mode-game-start-position)
                        (pygn-mode-game-end-position))
      (let ((last-point -1)
            (start (point))
            (thumb (point)))
        (when (pygn-mode-inside-header-p)
          (error "No more moves"))
        (dotimes (_ arg)
          (when (pygn-mode-looking-at-relaxed-legal-move)
            (setq thumb (point))
            (skip-chars-backward "0-9.…\s-")
            (backward-char 1))
          (while (and (not (= (point) last-point))
                      (or (not (pygn-mode-looking-at-relaxed-legal-move))
                          (pygn-mode-inside-variation-or-comment-p)))
            (setq last-point (point))
            (cond
              ((pygn-mode-inside-variation-or-comment-p)
               (pygn-mode-backward-exit-variations-and-comments))
              (t
               (skip-chars-backward "0-9.…\s-")
               (forward-sexp -1)))))
        (unless (pygn-mode-looking-at-relaxed-legal-move)
          (goto-char thumb)
          (when (= thumb start)
            (error "No more moves")))))))

(defun pygn-mode-select-game (pos)
  "Select current game in a multi-game PGN buffer.

When called non-interactively, select the game containing POS."
  (interactive "d")
  (goto-char pos)
  (push-mark (pygn-mode-game-end-position) t t)
  (goto-char (pygn-mode-game-start-position)))

(defun pygn-mode-echo-fen-at-pos (pos &optional do-copy)
  "Display the FEN corresponding to the point in the echo area.

When called non-interactively, display the FEN corresponding to POS.

With `prefix-arg' DO-COPY, copy the FEN to the kill ring, and to the system
clipboard when running a GUI Emacs."
  (interactive "d\nP")
  (let ((fen (pygn-mode-pgn-to-fen (pygn-mode-pgn-at-pos pos))))
    (when do-copy
      (kill-new fen)
      (when (and (fboundp 'gui-set-selection)
                 (display-graphic-p))
        (gui-set-selection 'CLIPBOARD fen)))
    (message "%s%s" fen (if do-copy (propertize "\t(copied)" 'face '(:foreground "grey33")) ""))))

(defun pygn-mode-flip-board ()
  "Flip the board display."
  (interactive)
  (setq pygn-mode-board-flipped (not pygn-mode-board-flipped))
  (pygn-mode-display-gui-board-at-pos (point)))

(defun pygn-mode-display-fen-at-pos (pos)
  "Display the FEN corresponding to the point in a separate buffer.

When called non-interactively, display the FEN corresponding to POS."
  (interactive "d")
  (let* ((fen (pygn-mode-pgn-to-fen (pygn-mode-pgn-at-pos pos)))
         (buf (get-buffer-create pygn-mode-fen-buffer-name))
         (win (get-buffer-window buf)))
    (with-current-buffer buf
      (erase-buffer)
      (insert fen)
      (goto-char (point-min))
      (display-buffer buf '(display-buffer-reuse-window))
      (unless win
        (setq win (get-buffer-window buf))
        (set-window-dedicated-p win t)
        (resize-temp-buffer-window win)))))

(defun pygn-mode-display-variation-fen-at-pos (pos)
  "Respecting variations, display the FEN corresponding to the point.

When called non-interactively, display the FEN corresponding to POS."
  (interactive "d")
  (let ((pgn (pygn-mode-pgn-at-pos-as-if-variation pos)))
    ;; todo it might be a better design if a temp buffer wasn't needed here
    (with-temp-buffer
      (insert pgn)
      (pygn-mode-display-fen-at-pos (point-max)))))

;; interactive helper
(defun pygn-mode--save-gui-board-at-pos (pos)
  "Save the board image corresponding to POS to a file."
  (let* ((pygn-mode-board-size (completing-read "Pixels per side: " nil nil nil nil nil pygn-mode-board-size))
         (filename (read-file-name "SVG filename: "))
         (svg-data (pygn-mode-pgn-to-board (pygn-mode-pgn-at-pos pos) 'svg)))
    (with-temp-buffer
      (insert svg-data)
      (write-file filename))))

(defun pygn-mode-display-gui-board-at-pos (pos)
  "Display a GUI board corresponding to the point in a separate buffer.

When called non-interactively, display the board corresponding to POS."
  (interactive "d")
  (let* ((svg-data (pygn-mode-pgn-to-board (pygn-mode-pgn-at-pos pos) 'svg))
         (buf (pygn-mode--get-or-create-board-buffer))
         (win (get-buffer-window buf)))
    (with-current-buffer buf
      (let ((buffer-read-only nil))
        (setq cursor-type nil)
        (erase-buffer)
        (insert-image (create-image svg-data 'svg t))))
    (display-buffer buf '(display-buffer-reuse-window))
    (unless win
      (setq win (get-buffer-window buf))
      (set-window-dedicated-p win t)
      (resize-temp-buffer-window win))))

(defun pygn-mode-display-text-board-at-pos (pos)
  "Display a text board corresponding to the point in a separate buffer.

When called non-interactively, display the board corresponding to POS."
  (interactive "d")
  (let* ((text-data (pygn-mode-pgn-to-board (pygn-mode-pgn-at-pos pos) 'text))
         (buf (pygn-mode--get-or-create-board-buffer))
         (win (get-buffer-window buf)))
    (with-current-buffer buf
      (let ((buffer-read-only nil))
        (erase-buffer)
        (insert (replace-regexp-in-string
                 "\\\\n" "\n"
                 text-data))
        (goto-char (point-min))))
    (display-buffer buf '(display-buffer-reuse-window))
    (unless win
      (setq win (get-buffer-window buf))
      (set-window-dedicated-p win t)
      (resize-temp-buffer-window win))))

(defun pygn-mode-display-board-at-pos (pos &optional arg)
  "Display a board corresponding to the point in a separate buffer.

When called non-interactively, display the board corresponding to POS.

The board format will be determined automatically based on
`display-graphic-p'.  To force a GUI or TUI board, call
`pygn-mode-display-gui-board-at-pos' or
`pygn-mode-display-text-board-at-pos' directly.

With optional universal prefix ARG, write a board image to a file,
prompting for image size."
  (interactive "d\nP")
  (cond
    (arg
     (pygn-mode--save-gui-board-at-pos pos))
    ((display-graphic-p)
     (pygn-mode-display-gui-board-at-pos pos))
    (t
     (pygn-mode-display-text-board-at-pos pos))))

(defun pygn-mode-mouse-display-variation-board (event)
  "Display the board corresponding to a mouse click in a separate buffer.

The mouse click corresponds to EVENT.

The board display respects variations."
  (interactive "@e")
  (set-buffer (window-buffer (posn-window (event-start event))))
  (goto-char (posn-point (event-start event)))
  (let ((pgn (pygn-mode-pgn-at-pos-as-if-variation (point))))
    ;; todo it might be a better design if a temp buffer wasn't needed here
    (with-temp-buffer
      (insert pgn)
      (pygn-mode-display-board-at-pos (point)))))

(defun pygn-mode-display-variation-board-at-pos (pos)
  "Respecting variations, display the board corresponding to the point.

When called non-interactively, display the board corresponding to POS."
  (interactive "d")
  (let ((pgn (pygn-mode-pgn-at-pos-as-if-variation pos)))
    ;; todo it might be a better design if a temp buffer wasn't needed here
    (with-temp-buffer
      (insert pgn)
      (pygn-mode-display-board-at-pos (point-max)))))

(defun pygn-mode-display-line-at-pos (pos)
  "Display the SAN line corresponding to the point in a separate buffer.

When called non-interactively, display the line corresponding to POS."
  (interactive "d")
  (let* ((line (pygn-mode-pgn-to-line (pygn-mode-pgn-at-pos pos)))
         (buf (get-buffer-create pygn-mode-line-buffer-name))
         (win (get-buffer-window buf)))
    (with-current-buffer buf
      (erase-buffer)
      (insert line)
      (goto-char (point-min))
      (display-buffer buf '(display-buffer-reuse-window))
      (unless win
        (setq win (get-buffer-window buf))
        (set-window-dedicated-p win t)
        (resize-temp-buffer-window win)))))

(defun pygn-mode-display-variation-line-at-pos (pos)
  "Display the SAN line corresponding to the point in a separate buffer.

When called non-interactively, display the line corresponding to POS.

The SAN line respects variations."
  (interactive "d")
  (let* ((line (pygn-mode-pgn-to-line (pygn-mode-pgn-at-pos-as-if-variation pos)))
         (buf (get-buffer-create pygn-mode-line-buffer-name))
         (win (get-buffer-window buf)))
    (with-current-buffer buf
      (erase-buffer)
      (insert line)
      (goto-char (point-min))
      (display-buffer buf '(display-buffer-reuse-window))
      (unless win
        (setq win (get-buffer-window buf))
        (set-window-dedicated-p win t)
        (resize-temp-buffer-window win)))))

(defun pygn-mode-previous-move-follow-board (arg)
  "Move back to the previous player move and display the updated board.

With numeric prefix ARG, move ARG moves backward."
  (interactive "p")
  (pygn-mode-previous-move arg)
  (pygn-mode-display-board-at-pos (point)))

(defun pygn-mode-next-move-follow-board (arg)
  "Advance to the next player move and display the updated board.

With numeric prefix ARG, move ARG moves forward."
  (interactive "p")
  (pygn-mode-next-move arg)
  (pygn-mode-display-board-at-pos (point)))

(defun pygn-mode-engine-go-depth (pos &optional depth)
  "Evaluate the position at POS in a `uci-mode' engine buffer.

DEPTH defaults to `pygn-mode-default-engine-depth'.  It may be overridden
directly as a numeric prefix argument, or prompted for interactively by
giving a universal prefix argument."
  (interactive "d\nP")
  (setq depth
        (cond
          ((numberp depth)
           depth)
          ((and depth (listp depth))
           (completing-read "Depth: " nil))
          (t
           pygn-mode-default-engine-depth)))
  (unless (and uci-mode-engine-buffer
               (window-live-p
                (get-buffer-window uci-mode-engine-buffer)))
    (uci-mode-run-engine))
  (let ((fen (pygn-mode-pgn-to-fen (pygn-mode-pgn-at-pos-as-if-variation pos))))
    (sleep-for 0.05)
    (uci-mode-send-stop)
    (uci-mode-send-commands
     (list (format "position fen %s" fen)
           (format "go depth %s" depth)))))

(defun pygn-mode-engine-go-time (pos &optional seconds)
  "Evaluate the position at POS in a `uci-mode' engine buffer.

SECONDS defaults to `pygn-mode-default-engine-time'.  It may be overridden
directly as a numeric prefix argument, or prompted for interactively by
giving a universal prefix argument."
  (interactive "d\nP")
  (setq seconds
        (cond
          ((numberp seconds)
           seconds)
          ((and seconds (listp seconds))
           (completing-read "Seconds: " nil))
          (t
           pygn-mode-default-engine-time)))
  (unless (and uci-mode-engine-buffer
               (window-live-p
                (get-buffer-window uci-mode-engine-buffer)))
    (uci-mode-run-engine))
  (let ((fen (pygn-mode-pgn-to-fen (pygn-mode-pgn-at-pos-as-if-variation pos))))
    (sleep-for 0.05)
    (uci-mode-send-stop)
    (uci-mode-send-commands
     (list (format "position fen %s" fen)
           (format "go time %s" seconds)))))

(defun pygn-mode-triple-window-layout-bottom ()
  "Set up three windows for PGN buffer, board image, and UCI interaction.

Place the board and UCI windows below the PGN window."
  (interactive)
  (unless (eq major-mode 'pygn-mode)
    (error "Select a buffer in `pygn-mode'"))
  (delete-other-windows)
  (split-window-vertically)
  (other-window 1)
  (switch-to-buffer
   (pygn-mode--get-or-create-board-buffer))
  (split-window-horizontally)
  (when (> (point-max) (point-min))
    (let ((fit-window-to-buffer-horizontally t))
      (fit-window-to-buffer (get-buffer-window (current-buffer)))))
  (other-window 1)
  (switch-to-buffer
   (get-buffer-create (or uci-mode-engine-buffer-name "*UCI*")))
  (set-window-scroll-bars
   (get-buffer-window (current-buffer)) nil nil nil 'bottom)
  (other-window 1))

(defun pygn-mode-triple-window-layout-right ()
  "Set up three windows for PGN buffer, board image, and UCI interaction.

Place the board and UCI windows to the right of the PGN window."
  (interactive)
  (unless (eq major-mode 'pygn-mode)
    (error "Select a buffer in `pygn-mode'"))
  (delete-other-windows)
  (split-window-horizontally)
  (other-window 1)
  (switch-to-buffer
   (pygn-mode--get-or-create-board-buffer))
  (split-window-vertically)
  (when (> (point-max) (point-min))
    (let ((fit-window-to-buffer-horizontally t))
      (fit-window-to-buffer (get-buffer-window (current-buffer)))))
  (other-window 1)
  (switch-to-buffer
   (get-buffer-create (or uci-mode-engine-buffer-name "*UCI*")))
  (set-window-scroll-bars
   (get-buffer-window (current-buffer)) nil nil nil 'bottom)
  (other-window 1))

(defun pygn-mode-ivy-jump-to-game-by-any-header ()
  "Navigate to a game by `ivy-completing-read' against header tagpairs.

Header tagpairs for which the value is \"?\" or empty are elided from
the search string."
  (interactive)
  (let* ((read-collection (pygn-mode-all-header-coordinates))
         (choice (ivy-completing-read "Choose Game: " read-collection)))
    (when (and choice (not (zerop (length choice))))
      (goto-char (cdr (assoc choice read-collection)))
      (pygn-mode-focus-game-at-point))))

(defun pygn-mode-ivy-jump-to-game-by-fen ()
  "Navigate to a game by `ivy-completing-read' against FEN tagpair values.

Games without FEN tagpairs are not represented in the search."
  (interactive)
  (let* ((read-collection (pygn-mode-fen-coordinates))
         (choice (ivy-completing-read "Choose Game: " read-collection)))
    (when (and choice (not (zerop (length choice))))
      (goto-char (cdr (assoc choice read-collection)))
      (pygn-mode-focus-game-at-point))))

(provide 'pygn-mode)

;;
;; Emacs
;;
;; Local Variables:
;; coding: utf-8
;; byte-compile-warnings: (not cl-functions redefine)
;; End:
;;
;; LocalWords: ARGS alist
;;

;;; pygn-mode.el ends here
