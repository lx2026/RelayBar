extension MarkdownRenderer {
    /// One reading design for both apps. A host changes the palette by redefining the
    /// custom properties after this sheet; nothing else is meant to be overridden.
    public static let stylesheet = """
    :root{color-scheme:light dark;--md-bg:#fff;--md-text:rgba(0,0,0,.85);--md-secondary:rgba(0,0,0,.55);--md-link:#2c65cf;--md-accent-rgb:0,122,255;--md-rule:rgba(0,0,0,.1);--md-rule-strong:rgba(0,0,0,.13);--md-fill:rgba(0,0,0,.045);--md-fill-edge:rgba(0,0,0,.09);--md-zebra:rgba(0,0,0,.035);--md-cell-edge:rgba(0,0,0,.14);--md-code:rgba(175,184,193,.24)}
    @media(prefers-color-scheme:dark){:root{--md-bg:#1e1e1e;--md-text:rgba(255,255,255,.85);--md-secondary:rgba(255,255,255,.55);--md-link:#4c8eec;--md-accent-rgb:10,132,255;--md-rule:rgba(255,255,255,.1);--md-rule-strong:rgba(255,255,255,.16);--md-fill:rgba(255,255,255,.045);--md-fill-edge:rgba(255,255,255,.09);--md-zebra:rgba(255,255,255,.035);--md-cell-edge:rgba(255,255,255,.14);--md-code:rgba(110,118,129,.4)}}
    html{-webkit-text-size-adjust:100%}
    body{margin:0;background:var(--md-bg);color:var(--md-text);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;overflow-wrap:break-word}
    article{max-width:680px;margin:0 auto;padding:28px 32px 40px}
    article>:first-child{margin-top:0}
    article>:last-child{margin-bottom:0}
    p,ul,ol,dl{margin:0 0 16px}
    h1,h2,h3,h4,h5,h6{margin:24px 0 16px;font-weight:600;line-height:1.25}
    h1{font-size:2em;padding-bottom:.3em;border-bottom:1px solid var(--md-rule)}
    h2{font-size:1.5em;padding-bottom:.3em;border-bottom:1px solid var(--md-rule)}
    h3{font-size:1.25em}
    h4{font-size:1em}
    h5{font-size:.875em}
    h6{font-size:.85em;color:var(--md-secondary)}
    strong{font-weight:600}
    a{color:var(--md-link);text-decoration:none}
    a:hover{text-decoration:underline}
    hr{height:4px;margin:24px 0;border:0;border-radius:2px;background:var(--md-rule-strong)}
    img{max-width:100%;height:auto}
    article img:not(.math){border-radius:4px}
    ul,ol{padding-left:2em}
    li{margin:.25em 0}
    li>ul,li>ol{margin:.25em 0 0}
    li>p{margin:0 0 8px}
    li:has(>input[type=checkbox]){list-style:none}
    li>input[type=checkbox]{-webkit-appearance:none;appearance:none;box-sizing:border-box;width:14px;height:14px;margin:0 .5em 0 -1.45em;vertical-align:-1.5px;border:1.5px solid var(--md-secondary);border-radius:3.5px;opacity:1}
    li>input[type=checkbox]:checked{border-color:transparent;background:rgb(var(--md-accent-rgb)) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 14 14'%3E%3Cpath d='M3.4 7.4l2.4 2.4 4.8-5.4' fill='none' stroke='white' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center/14px 14px no-repeat}
    li>input[type=checkbox]+p{display:inline}
    blockquote{margin:0 0 16px;padding:12px 14px;border-left:3px solid rgba(var(--md-accent-rgb),.75);border-radius:7px;background:rgba(var(--md-accent-rgb),.065);box-shadow:inset 0 0 0 1px rgba(var(--md-accent-rgb),.12)}
    blockquote>:last-child{margin-bottom:0}
    blockquote blockquote{margin-top:12px}
    :not(pre)>code{padding:.15em .38em;border-radius:5px;background:var(--md-code);font:.85em ui-monospace,"SF Mono",Menlo,monospace}
    pre{margin:0;font:12px/1.5 ui-monospace,"SF Mono",Menlo,monospace;tab-size:4;overflow-x:auto}
    pre code{font:inherit}
    article>pre{margin:0 0 16px;padding:14px;border-radius:7px;background:var(--md-fill);box-shadow:inset 0 0 0 1px var(--md-fill-edge);white-space:pre-wrap}
    figure.code{margin:0 0 16px;border-radius:7px;background:var(--md-fill);box-shadow:inset 0 0 0 1px var(--md-fill-edge);overflow:hidden}
    figure.code figcaption{border-bottom:1px solid var(--md-rule)}
    figure.code .bar{display:flex;align-items:center;justify-content:space-between;height:34px;padding:0 6px 0 12px}
    figure.code .language{color:var(--md-secondary);font:500 10.5px ui-monospace,"SF Mono",Menlo,monospace}
    figure.code .copy{padding:3px 7px;border-radius:5px;color:var(--md-text);font:500 11px -apple-system,sans-serif;text-decoration:none;-webkit-user-select:none;user-select:none}
    figure.code .copy:hover{background:var(--md-fill-edge)}
    figure.code .copy:active{opacity:.55}
    figure.code .copy.done::after{content:"\\2009\\2713"}
    figure.code .note,.math-display .note{color:var(--md-secondary);font:500 10.5px -apple-system,sans-serif}
    figure.code .note{padding:0 12px 9px}
    figure.code pre{padding:14px}
    figure.code pre.dark{display:none}
    @media(prefers-color-scheme:dark){figure.code pre.light{display:none}figure.code pre.dark{display:block}}
    .table-scroll{margin:0 0 16px;overflow-x:auto}
    table{border-collapse:collapse;max-width:100%}
    th,td{padding:6px 13px;border:1px solid var(--md-cell-edge);vertical-align:top}
    th{font-weight:600}
    th:not([align]){text-align:left}
    tbody tr:nth-child(even){background:var(--md-zebra)}
    img.math{max-width:100%;opacity:.85}
    em:has(>img.math),em:has(>.math-display){font-style:normal}
    .math-display{display:block;padding:14px;border-radius:7px;background:var(--md-fill);box-shadow:inset 0 0 0 1px var(--md-fill-edge);text-align:center;overflow-x:auto}
    .math-display img.math{max-height:180px;object-fit:contain;vertical-align:middle}
    .math-display.failed{text-align:left}
    .math-display .note{display:block;margin-bottom:5px}
    @media(prefers-color-scheme:dark){img.math{filter:invert(1)}}
    """
}
