#!/usr/bin/env python
#
# pgn_to_board
#
# return the SVG board after the last move in a PGN input file
#
# notes
#
#     requires python-chess
#
# bugs
#
# todo
#

###
### version
###

__version__ = '1.00'

###
### imports
###

import sys
import argparse
import textwrap
import signal
import chess.pgn
import chess.svg

###
### file-scoped configurable variables
###

###
### subroutines
###

###
### argument processing
###

def generate_argparser():
    argparser = argparse.ArgumentParser(description=textwrap.dedent(
                                        '''
                                        Return the SVG board after the last move in a PGN <file>.
                                        '''),
                                        formatter_class=argparse.RawDescriptionHelpFormatter)
    argparser.add_argument('file',
                           metavar='<file>',
                           nargs='*',
                           type=argparse.FileType('r'),
                           help='File to analyze.  Input on the standard input is also accepted.')
    argparser.add_argument('-quiet', '--quiet',
                           action='store_true',
                           help='Emit less diagnostic output.')
    argparser.add_argument('-verbose', '--verbose',
                           action='store_true',
                           help='Emit more diagnostic output.')
    argparser.add_argument('-help',
                           action='help',
                           help=argparse.SUPPRESS)
    argparser.add_argument('-version', '--version',
                           action='version',
                           version=__version__)
    return argparser

###
### main
###

if __name__ == '__main__':
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    argparser = generate_argparser()
    if sys.stdin.isatty() and len(sys.argv) == 1:
        args = argparser.parse_args(['--help'])
    else:
        args = argparser.parse_args()

    if args.quiet and args.verbose:
        print('pgn_to_fen: -quiet and -verbose are incompatible', file=sys.stderr)
        exit(1)

    input_files = args.file
    if not sys.stdin.isatty():
        input_files = [sys.stdin, *input_files]

    # should only be a single input file in the array
    for input_file in input_files:
        game = chess.pgn.read_game(input_file)
        board = game.board()
        for move in game.mainline_moves():
            board.push(move)
        print(chess.svg.board(board=board))

#
# Emacs
#
# Local Variables:
# coding: utf-8
# End:
#
# LocalWords:
#
