
import macros
import strutils
import tables

export escape

const DEBUG = false

type
  Opcode = enum
    opChoice, opCommit, opCall, opReturn, opAny, opSet, opStr,
    opIStr, opFail

  Inst = object
    case op: Opcode
      of opChoice, opCommit:
        offset: int
      of opStr, opIStr:
        str: string
      of opCall:
        name: string
        address: int
      of opSet:
        cs: set[char]
      of opFail, opReturn, opAny:
        discard

  Frame* = object
    ip: int
    si: int

  Patt = seq[Inst]

  Patts = Table[string, Patt]


proc dumpset(cs: set[char]): string =
  proc esc(c: char): string =
    case c:
      of '\n': result = "\\n"
      of '\r': result = "\\r"
      of '\t': result = "\\t"
      else: result = $c
    result = "'" & result & "'"
  result.add "{"
  var c = 0
  while c <= 255:
    let first = c
    while c <= 255 and c.char in cs:
      inc c
    if (c - 1 == first):
      result.add esc(first.char) & ","
    elif c - 1 > first:
      result.add esc(first.char) & ".." & esc((c-1).char) & ","
    inc c
  if result[result.len-1] == ',': result.setLen(result.len-1)
  result.add "}"


proc `$`*(p: Patt): string =
  for n, i in p.pairs:
    result &= $n & ": " & $i.op
    case i.op:
      of opStr:
        result &= escape(i.str)
      of opIStr:
        result &= "i" & escape(i.str)
      of opSet:
        result &= " '" & dumpset(i.cs) & "'"
      of opChoice, opCommit:
        result &= " " & $(n+i.offset)
      of opCall:
        result &= " " & i.name & ":" & $i.address
      of opFail, opReturn, opAny:
        discard
    result &= "\n"


#
# Some tests on patterns
#

proc isSet(p: Patt): bool =
  p.len == 1 and p[0].op == opSet 

  
#
# Recursively compile a peg pattern to a sequence of parser instructions
#

proc buildPatt(patts: Patts, name: string, patt: NimNode): Patt =

  proc aux(n: NimNode): Patt =

    template add(p: Inst|Patt) =
      result.add p

    template addLoop(p: Patt) =
      add Inst(op: opChoice, offset: p.len+2)
      add p
      add Inst(op: opCommit, offset: -p.len-1)

    template addMaybe(p: Patt) =
      add Inst(op: opChoice, offset: p.len + 2)
      add p
      add Inst(op: opCommit, offset: 1)

    case n.kind:
      of nnKPar:
        add aux(n[0])
      of nnkStrLit:
        add Inst(op: opStr, str: n.strVal)
      of nnkCharLit:
        add Inst(op: opStr, str: $n.intVal.char)
      of nnkPrefix:
        let p = aux n[1]
        if n[0].eqIdent("?"):
          addMaybe p
        elif n[0].eqIdent("+"):
          add p
          addLoop p
        elif n[0].eqIdent("*"):
          addLoop p
        elif n[0].eqIdent("-"):
          add Inst(op: opChoice, offset: p.len + 3)
          add p
          add Inst(op: opCommit, offset: 1)
          add Inst(op: opFail)
        else:
          error "PEG: Unhandled prefix operator"
      of nnkInfix:
        let p1 = aux n[1]
        let p2 = aux n[2]
        if n[0].eqIdent("*"):
          add p1
          add p2
        elif n[0].eqIdent("-"):
          add Inst(op: opChoice, offset: p2.len + 3)
          add p2
          add Inst(op: opCommit, offset: 1)
          add Inst(op: opFail)
          add p1
        elif n[0].eqIdent("|"):
          if p1.isset and p2.isset:
            add Inst(op: opSet, cs: p1[0].cs + p2[0].cs)
          else:
            add Inst(op: opChoice, offset: p1.len+2)
            add p1
            add Inst(op: opCommit, offset: p2.len+1)
            add p2
        else:
          error "PEG: Unhandled infix operator " & n.repr
      of nnkCurlyExpr:
        let p = aux(n[0])
        let min = n[1].intVal
        for i in 1..min:
          add p
        if n.len == 3:
          let max = n[2].intval
          for i in min..max:
            addMaybe p
      of nnkIdent:
        let name = n.strVal
        if name in patts:
          add patts[name]
        else:
          add Inst(op: opCall, name: n.strVal)
      of nnkCurly:
        var cs: set[char]
        for nc in n:
          if nc.kind == nnkCharLit:
            cs.incl nc.intVal.char
          elif nc.kind == nnkInfix and nc[0].kind == nnkIdent and nc[0].eqIdent(".."):
            for c in nc[1].intVal..nc[2].intVal:
              cs.incl c.char
          else:
            error "PEG: syntax error: " & n.repr & "\n" & n.astGenRepr
        if cs.card == 0:
          add Inst(op: opAny)
        else:
          add Inst(op: opSet, cs: cs)
      of nnkCallStrLit:
        if n[0].eqIdent("i"):
          add Inst(op: opIStr, str: n[1].strVal)
        else:
          error "PEG: unhandled string prefix"
      else:
        error "PEG: syntax error: " & n.repr & "\n" & n.astGenRepr
 
  result = aux(patt)


#
# Compile the PEG to a table of patterns
#

proc compile(ns: NimNode): Patts =
  result = initTable[string, Patt]()

  ns.expectKind nnkStmtList
  for n in ns:
    n.expectKind nnkInfix
    n[0].expectKind nnkIdent
    n[1].expectKind nnkIdent
    if not n[0].eqIdent("<-"):
      error("Expected <-")
    let pname = n[1].strVal
    result[pname] = buildPatt(result, pname, n[2])


#
# Link all patterns into a grammar, which is itself again a valid pattern.
# Start with the initial rule, add all other non terminals and fixup opCall
# addresses
#

proc link(patts: Patts, initial_name: string): Patt =

  if initial_name notin patts:
    error "inital pattern '" & initial_name & "' not found"

  var grammar: Patt
  var symTab = newTable[string, int]()

  # Recursively emit a pattern, and all patterns it calls which are
  # not yet emitted

  proc emit(name: string) =
    echo "Emit rule " & name
    let patt = patts[name]
    symTab[name] = grammar.len
    grammar.add patt
    grammar.add Inst(op: opReturn)

    for i in patt:
      if i.op == opCall and i.name notin symTab:
        emit i.name
  
  emit initial_name

  # Fixup grammar call addresses

  for i in grammar.mitems:
    if i.op == opCall:
      i.address = symtab[i.name]

  return grammar

#
# Template for generating the parsing match proc
#

template skel(cases: untyped) =
  var si = 0
  var sp = 0
  var stack = newSeq[Frame](128)

  template trace(msg: string) =
    when DEBUG:
      let si2 = min(si+10, s.len-1)
      var l = align($ip, 3) &
           " | " & align($si, 3) & 
           " " & alignLeft(s[si..si2], 24) & 
           "| " & alignLeft(msg, 30) &
           "| " & alignLeft(repeat("*", sp), 20) 
      if sp > 0:
        l.add $stack[sp]
      echo l


  template opIStrFn(s2: string) =
    let l = s2.len
    if si <= s.len - l and cmpIgnoreCase(s[si..<si+l], s2) == 0:
      inc ip
      inc si, l
    else:
      ip = -1
    trace "str " & s2.escape
  
  template opStrFn(s2: string) =
    let l = s2.len
    if si <= s.len - l and s[si..<si+l] == s2:
      inc ip
      inc si, l
    else:
      ip = -1
    trace s2.escape

  template opSetFn(cs: set[char]) =
    if si < s.len and s[si] in cs:
      inc ip
      inc si
    else:
      ip = -1
    trace dumpset(cs)

  template opAnyFn() =
    if si < s.len:
      inc ip
      inc si
    else:
      ip = -1
    trace "any"

  template push(ip2: int, si2: int = -1) =
    stack[sp].ip = ip2
    stack[sp].si = si2
    inc sp
    inc ip

  template opChoiceFn(n: int) =
    push(n, si)
    trace "choice -> " & $n

  template opCommitFn(n: int) =
    dec sp
    trace "commit -> " & $n
    ip = n

  template opCallFn(label: string, address: int) =
    stack[sp].ip = ip+1
    stack[sp].si = -1
    inc sp
    ip = address
    trace "call -> " & label & ":" & $address

  template opReturnFn() =
    if sp == 0:
      trace "done"
      return true
    dec sp
    ip = stack[sp].ip
    trace "return"

  template opFailFn() =
    while sp > 0 and stack[sp-1].si == -1:
      dec sp
    

    if sp == 0:
      trace "\e[31;1merror\e[0m --------------"
      return

    dec sp
    ip = stack[sp].ip
    si = stack[sp].si
    trace "fail -> " & $ip

  while true:
    cases

#
# Convert the list of parser instructions into a Nim finite state machine
#

proc gencode(name: string, program: Patt): NimNode =

  # Create case handler for each instruction

  var cases = nnkCaseStmt.newTree(ident("ip"))
  cases.add nnkElse.newTree(parseStmt("opFailFn()"))
  
  for n, i in program.pairs:
    let call = nnkCall.newTree(ident($i.op & "Fn"))
    case i.op:
      of opStr, opIStr:      call.add newStrLitNode(i.str)
      of opSet:
        let setNode = nnkCurly.newTree()
        for c in i.cs: setNode.add newLit(c)
        call.add setNode
      of opChoice, opCommit: call.add newIntLitNode(n + i.offset)
      of opCall:             
        call.add newStrLitNode(i.name)
        call.add newIntLitNode(i.address)
      else: discard
    cases.add nnkOfBranch.newTree(newLit(n), call)

  var body = nnkStmtList.newTree()
  body.add parseStmt("var ip = 0")
  #body.add parseStmt("var si = 0")
  #body.add parseStmt("var stack: seq[Frame]")
  body.add getAst skel(cases)

  # Return parser lambda function containing 'body'

  result = nnkLambda.newTree(
    newEmptyNode(), newEmptyNode(), newEmptyNode(),
    nnkFormalParams.newTree(
      newIdentNode("bool"),
      nnkIdentDefs.newTree(
        newIdentNode("s"), newIdentNode("string"),
        newEmptyNode()
      )
    ),
    newEmptyNode(), newEmptyNode(),
    body
  )

  #echo result.repr


#
# Convert a pattern to a Nim proc implementing the parser state machine
#

macro peg*(name: string, ns: untyped): untyped =
  let grammar = compile(ns)
  let patt = link(grammar, name.strVal)
  #echo patt
  let program = gencode(name.strVal, patt)
  echo program.repr
  program


