"""
    c = @sc_ircode f(args...)

Julia SSA IR explore.

```julia
c                  # view IR in the REPL
display(c)         # (ditto)

c.cfg              # control-flow graph (CFG) visualizer
c.cfg_only         # CFG without IR in node label
c.dom              # dominator tree visualizer
c.dom_only         # dominator tree without IR in node label
display(c.cfg)     # display CFG

c.llvm             # create LLVM IR explore
c.native           # create native code explore
c.att              # (ditto)
c.intel            # create native code explore in intel syntax
edit(c.native)
abspath(c.native)
```

... and so on; type `c.` + TAB to see the full list.

Since visualizers such as `c.cfg` and `c.cfg_only` work via the standard
`show` mechanism, they interoperable well with other packages like FileIO.jl
and DisplayAs.jl.

```julia
using FileIO
save("PATH/TO/IMAGE.png", c.cfg_only)
save("PATH/TO/IMAGE.svg", c.cfg_only)
save("PATH/TO/IMAGE.pdf", c.cfg_only)

using DisplayAs
c.cfg_only |> DisplayAs.SVG
```
"""
:(@sc_ircode)

struct IRCodeView <: AbstractCode
    ir::Core.Compiler.IRCode
    f::Any
    atype::Any
    rtype::Union{Type,Nothing}
    args::Any
    kwargs::Any
end

macro sc_ircode(args...)
    gen_call_with_extracted_types_and_kwargs(__module__, sc_ircode, args)
end

function sc_ircode(f, argument_type; kwargs...)
    @nospecialize
    # TODO: handle multiple returns?
    (ir, rtype), = code_ircode(f, argument_type; kwargs...)
    args = (f, argument_type)
    return IRCodeView(ir, f, argument_type, rtype, args, kwargs)
end

function sc_ircode(mi::Core.Compiler.MethodInstance; kwargs...)
    @nospecialize
    mth = mi.def
    if mth isa Method
        ftype = Base.tuple_type_head(mth.sig)
        if Base.issingletontype(ftype)
            f = ftype.instance
        else
            f = ftype  # ?
        end
        atype = Base.tuple_type_tail(mth.sig)
    else
        f = "f?"
        atype = "Tuple{?}"
    end

    args = (mi,)
    ir, rtype = code_ircode(args...; kwargs...)
    return IRCodeView(ir, f, atype, rtype, args, kwargs)
end

function sc_ircode(ir::Core.Compiler.IRCode; kwargs...)
    f = "f?"
    atype = "Tuple{?}"
    rtype = nothing
    args = (ir,)
    return IRCodeView(ir, f, atype, rtype, args, kwargs)
end

function sc_ircode(ci::Core.Compiler.CodeInfo; kwargs...)
    ir = CompilerUtils.ircode_from_codeinfo(ci)
    f = ci.parent.def.name
    atype = Base.tuple_type_tail(ci.parent.def.sig)
    rtype = ci.rettype
    args = (ci,)
    return IRCodeView(ir, f, atype, rtype, args, kwargs)
end

function Base.summary(io::IO, llvm::IRCodeView)
    @unpack f, atype = Fields(llvm)
    print(io, "IRCodeView of ", f, " with ", atype)
    return
end

function show_ir_config(ir; debuginfo = :default)
    if debuginfo === :source
        return Base.IRShow.default_config(ir; verbose_linetable = true)
    else
        return Base.IRShow.default_config(ir; verbose_linetable = false)
    end
end

function _show_ir(io::IO, ir::Core.Compiler.IRCode; options...)
    if isempty(options)
        show(io, MIME"text/plain"(), ir)
        return
    end
    Base.IRShow.show_ir(io, ir, show_ir_config(ir; options...))
end

function Base.show(io::IO, ::MIME"text/plain", ircv::IRCodeView; options...)
    @unpack ir, rtype = Fields(ircv)
    summary(io, ircv)
    println(io)
    _show_ir(io, ir; options...)
    print(io, "⇒ ", rtype)
    println(io)
    return
end

Base.propertynames(::IRCodeView) = (
    :ir,
    :rtype,
    # explores:
    :llvm,
    :native,
    :intel,
    :att,
    # visualizers:
    :cfg,
    :cfg_only,
    :dom,
    :dom_only,
)

function Base.getproperty(ircv::IRCodeView, name::Symbol)
    @unpack args = Fields(ircv)
    if name === :llvm
        return sc_llvm(args...)
    elseif name === :native || name === :att
        return sc_native(args...)
    elseif name === :intel
        return sc_intel(args...)
    elseif name === :cfg
        return IRCodeCFGDot(ircv, true)
    elseif name === :cfg_only
        return IRCodeCFGDot(ircv, false)
    elseif name === :dom
        return IRCodeDomTree(ircv, true)
    elseif name === :dom_only
        return IRCodeDomTree(ircv, false)
    end
    return getfield(ircv, name)
end

abstract type AbstractLazyDot <: AbstractCode end

function dot_to_iobuffer(dot)
    io = IOBuffer()
    print_dot(io, dot)
    seekstart(io)
    return io
end

using Graphviz_jll

function run_dot(output::IO, input::IO, options)
    cmd = `$(dot()) -Gfontname=monospace -Nfontname=monospace -Efontname=monospace $options`
    @debug "Run: $cmd"
    run(pipeline(cmd, stdout = output, stderr = stderr, stdin = input))
    return
end

# https://www.iana.org/assignments/media-types/text/vnd.graphviz
Base.show(io::IO, ::MIME"text/vnd.graphviz", dot::AbstractLazyDot) = print_dot(io, dot)

Base.show(io::IO, ::MIME"image/png", dot::AbstractLazyDot) =
    run_dot(io, dot_to_iobuffer(dot), `-Tpng`)
Base.show(io::IO, ::MIME"image/svg+xml", dot::AbstractLazyDot) =
    run_dot(io, dot_to_iobuffer(dot), `-Tsvg`)
Base.show(io::IO, ::MIME"application/pdf", dot::AbstractLazyDot) =
    run_dot(io, dot_to_iobuffer(dot), `-Tpdf`)

struct IRCodeCFGDot <: AbstractLazyDot
    ircv::IRCodeView
    include_code::Bool
end

function escape_dot_label(io::IO, str)
    for c in str
        if c in "\\{}<>|\"\n"
            # https://graphviz.org/doc/info/attrs.html#k:escString
            print(io, '\\', c)
        else
            print(io, c)
        end
    end
end

function Base.summary(io::IO, dot::IRCodeCFGDot)
    @unpack ircv = Fields(dot)
    @unpack f, atype = Fields(ircv)
    print(io, "CFG of $f on $atype")
end

function find_syncregions(ir, bb)
    ids = Int[]
    for i in bb.stmts
        inst = ir.stmts[i][:inst]
        if inst isa Expr && inst.head === :syncregion
            push!(ids, i)
        end
    end
    return ids
end


print_stmt(io, x) = print(io, x)

function print_stmt(io, ex::Expr)
    if Meta.isexpr(ex, :enter, 1)
        print(io, "enter #", ex.args[1])
    elseif ex.head in (:leave, :pop_exception)
        print(io, ex.head)
        for a in ex.args
            print(io, ' ')
            print(io, a)
        end
    else
        print(io, ex)
    end
end

function print_stmt(io::IO, x::Core.GotoNode)
    @unpack label = x
    print(io, "goto #", label)
end

function print_stmt(io::IO, x::Core.GotoIfNot)
    @unpack cond, dest = x
    print(io, "goto #", dest, " if not ", cond)
end

function print_bb_stmts_for_dot_label(io, ir, bb)
    for s in bb.stmts
        ln = sprint() do io
            print(io, "%", s, " = ")
            print_stmt(io, ir.stmts.inst[s])
        end
        escape_dot_label(io, ln)
        print(io, "\\l")
    end
end

print_dot(dot) = print_dot(stdout, dot)
function print_dot(io::IO, dot::IRCodeCFGDot)
    @unpack ircv, include_code = Fields(dot)
    @unpack ir = Fields(ircv)

    function bblabel(i)
        inst = ir.stmts.inst[ir.cfg.blocks[i].stmts[end]]
        if inst isa Core.ReturnNode
            if isdefined(inst, :val)
                return "#$(i)⏎"
            else
                return "#$(i)⚠"
            end
        end
        ids = find_syncregions(ir, ir.cfg.blocks[i])
        if !isempty(ids)
            return "#$i SR(" * join(("%$i" for i in ids), ", ") * ")"
        end
        return string("#", i)
    end

    graphname = summary(dot)
    print(io, "digraph \"")
    escape_dot_label(io, graphname)
    println(io, "\" {")
    indented(args...) = print(io, "    ", args...)
    indented("label=\"")
    escape_dot_label(io, graphname)
    println(io, "\";")
    for (i, bb) in enumerate(ir.cfg.blocks)
        indented(i, " [shape=record")

        # Print code
        if include_code
            print(io, ", label=\"{$(bblabel(i)):\\l")
        else
            print(io, ", label=\"{$(bblabel(i))}\", tooltip=\"")
        end
        print_bb_stmts_for_dot_label(io, ir, bb)
        if include_code
            print(io, "}\"")
        else
            print(io, '"')
        end
        println(io, "];")

        # Print edges
        term = ir.stmts[bb.stmts[end]][:inst]
        if term isa DetachNode && length(bb.succs) == 2 && term.label in bb.succs
            det, = (i for i in bb.succs if i != term.label)
            cont = term.label
            indented(i, " -> ", cont, " [label = \" C($(term.syncregion))\"];\n")
            indented(i, " -> ", det, " [label = \" D($(term.syncregion))\"];\n")
        elseif term isa ReattachNode && length(bb.succs) == 1 && bb.succs[1] == term.label
            indented(i, " -> ", term.label, " [label = \" R($(term.syncregion))\"];\n")
        elseif term isa SyncNode && length(bb.succs) == 1
            indented(i, " -> ", bb.succs[1], " [label = \" S($(term.syncregion))\"];\n")
        else
            if term isa Expr && term.head === :enter
                attr = "label = \" E\""
            elseif term isa Expr && term.head === :leave
                attr = "label = \" L\""
            else
                attr = ""
            end
            for s in bb.succs
                attr2 = i == s ? "dir = back " : ""
                indented(i, " -> ", s, " [", attr2, attr, "]", ";\n")
            end
        end
    end
    println(io, '}')
end

struct IRCodeDomTree <: AbstractLazyDot
    ircv::IRCodeView
    include_code::Bool
    domtree::Core.Compiler.DomTree
end

function IRCodeDomTree(ircv::IRCodeView, include_code::Bool)
    @unpack ir = Fields(ircv)
    domtree = Core.Compiler.construct_domtree(ir.cfg.blocks)
    return IRCodeDomTree(ircv, include_code, domtree)
end

function Base.summary(io::IO, d::IRCodeDomTree)
    @unpack f, atype = Fields(Fields(d).ircv)
    print(io, "Dominator tree for $f on $atype")
end

# https://github.com/JuliaDebug/Cthulhu.jl/issues/26
AbstractTrees.treekind(::IRCodeDomTree) = AbstractTrees.IndexedTree()
AbstractTrees.childindices(d::IRCodeDomTree, i::Int) = d[i].children
AbstractTrees.childindices(::IRCodeDomTree, ::IRCodeDomTree) = (1,)
AbstractTrees.parentlinks(::IRCodeDomTree) = AbstractTrees.StoredParents()
AbstractTrees.printnode(io::IO, i::Int, ::IRCodeDomTree) = print(io, i)
Base.getindex(d::IRCodeDomTree, i) = Fields(d).domtree.nodes[i]

function Base.show(io::IO, ::MIME"text/plain", d::IRCodeDomTree)
    summary(io, d)
    println(io)
    AbstractTrees.print_tree(io, 1; roottree = d)
end

function print_dot(io::IO, dot::IRCodeDomTree)
    @unpack ircv, domtree, include_code = Fields(dot)
    @unpack ir = Fields(ircv)

    graphname = summary(dot)
    print(io, "digraph \"")
    escape_dot_label(io, graphname)
    println(io, "\" {")
    indented(args...) = print(io, "    ", args...)
    indented("label=\"")
    escape_dot_label(io, graphname)
    println(io, "\";")

    @assert length(domtree.nodes) == length(ir.cfg.blocks)
    for (i, (node, bb)) in enumerate(zip(domtree.nodes, ir.cfg.blocks))
        indented(i, " [shape=record")

        # Print code
        if include_code
            print(io, ", label=\"{$i:\\l")
        else
            print(io, ", label=\"{$i}\", tooltip=\"")
        end
        print_bb_stmts_for_dot_label(io, ir, bb)
        if include_code
            print(io, "}\"")
        else
            print(io, '"')
        end
        println(io, "];")

        # Print edges
        for s in node.children
            indented(i, " -> ", s, ";\n")
        end
    end
    println(io, '}')
end
