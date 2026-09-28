import Foundation

enum WebGalleryPage {
    static let html = #"""
    <!doctype html>
    <html lang="zh-Hant">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <meta name="color-scheme" content="dark light">
      <title>相片圖庫</title>
      <style>
        :root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color-scheme:dark;color:#f5f5f7;background:#080809;--surface:#1c1c1e;--bar:#242427;--hover:#333338;--line:#38383b;--text:#f5f5f7;--muted:#a4a4aa;--accent:#7daaff;--grid:#080809}
        *{box-sizing:border-box}html,body{margin:0;height:100%;overflow:hidden}body{font-size:14px}button,input,select{font:inherit}button{cursor:pointer}button:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--accent);outline-offset:2px}[hidden]{display:none!important}
        .app{display:flex;height:100dvh;min-height:0}.sidebar{width:248px;flex:none;overflow:auto;background:var(--surface);border-right:1px solid var(--line);padding:20px 10px 26px}.sidebar-brand{display:flex;align-items:center;gap:10px;padding:0 12px 23px;font-size:17px;font-weight:650;letter-spacing:-.02em}.brand-icon{display:grid;place-items:center;width:30px;height:30px;border-radius:8px;background:linear-gradient(135deg,#ba71fa,#5aa8ff);color:white}.side-heading{padding:17px 12px 6px;text-transform:uppercase;color:var(--muted);font-size:11px;font-weight:700;letter-spacing:.06em}.side-link,.album-link{display:flex;align-items:center;gap:10px;width:100%;padding:8px 12px;border:0;border-radius:8px;color:var(--text);background:transparent;text-align:left;min-height:36px}.side-link:hover,.album-link:hover{background:var(--hover)}.side-link.active,.album-link.active{background:#3869ad;color:#fff}.side-icon{width:19px;text-align:center;font-size:18px;display:grid;place-items:center}.side-icon svg{display:block;width:19px;height:19px;color:var(--accent)}.side-count{margin-left:auto;color:var(--muted);font-size:11px}.album-link{padding-left:39px;font-size:13px}.workspace{display:flex;flex-direction:column;min-width:0;flex:1;background:var(--grid)}.topbar{height:63px;flex:none;display:flex;align-items:center;gap:16px;padding:0 22px;background:var(--bar);border-bottom:1px solid var(--line)}.page-heading{min-width:155px;max-width:28%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:17px;font-weight:640}.toolbar-center{display:flex;align-items:center;justify-content:center;flex:1;gap:10px}.segment{display:flex;padding:2px;gap:2px;border-radius:8px;background:#111113}.segment button{border:0;background:transparent;color:var(--muted);padding:6px 12px;border-radius:6px;white-space:nowrap}.segment button.active{background:#55555a;color:#fff}.zoom{display:flex;align-items:center;gap:2px}.zoom button,.icon-button{border:0;color:var(--text);background:transparent;border-radius:8px;min-width:31px;min-height:31px;font-size:19px}.zoom button:hover,.icon-button:hover{background:var(--hover)}.desktop-search{display:flex;align-items:center;gap:6px;width:min(225px,25vw);background:#111113;border:1px solid var(--line);border-radius:8px;padding:6px 9px;color:var(--muted)}.desktop-search input,.mobile-search input{width:100%;border:0;outline:0;background:transparent;color:var(--text);min-width:0}.desktop-search input::placeholder,.mobile-search input::placeholder{color:var(--muted)}.content{overflow:auto;min-height:0;flex:1;overscroll-behavior:contain}.content-inner{min-height:100%;padding-bottom:40px}.mobile-header,.bottom-nav,.mobile-timeline{display:none}.content-title{display:flex;align-items:end;justify-content:space-between;gap:16px;padding:21px 24px 13px}.content-title h1{font-size:23px;letter-spacing:-.02em;margin:0;font-weight:680}.subline{color:var(--muted);font-size:12px;margin:4px 0 0}.back-button{border:0;background:transparent;color:var(--accent);padding:0;margin-bottom:9px}.count-label{color:var(--muted);font-size:12px;white-space:nowrap}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(var(--tile-size,140px),1fr));gap:1px;background:var(--grid);padding:1px}.tile{position:relative;aspect-ratio:1;overflow:hidden;display:block;border:0;padding:0;background:#262629;border-radius:0}.tile img{display:block;width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity .18s}.tile img.loaded{opacity:1}.tile:hover:after,.tile:focus-visible:after{content:"";position:absolute;inset:0;box-shadow:inset 0 0 0 3px var(--accent);pointer-events:none}.placeholder{position:absolute;inset:0;display:grid;place-items:center;color:#666;font-size:22px}.tile-label{position:absolute;bottom:0;left:0;right:0;padding:20px 6px 5px;text-align:left;color:white;font-size:11px;background:linear-gradient(transparent,#0009);opacity:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}.tile:hover .tile-label,.tile:focus-visible .tile-label{opacity:1}.load-row{padding:24px;text-align:center}.load-button,.status button{border:1px solid var(--line);background:var(--bar);border-radius:9px;color:var(--text);padding:8px 16px}.load-button:disabled{opacity:.45}.status{padding:12vh 24px;text-align:center;color:var(--muted)}.status h2{font-size:19px;color:var(--text);font-weight:600;margin:0 0 8px}.status p{margin:0 0 18px}.collection-section{padding:16px 24px 7px}.collection-section h2{font-size:17px;margin:0 0 13px}.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(175px,1fr));gap:14px}.cards.period-cards{grid-template-columns:repeat(4,minmax(0,1fr))}.card{border:0;border-radius:12px;overflow:hidden;background:var(--surface);color:var(--text);text-align:left;padding:0}.card-cover{display:block;aspect-ratio:1.35;position:relative;background:#303034;overflow:hidden}.card-cover img{width:100%;height:100%;object-fit:cover}.card-title{display:block;font-weight:600;padding:10px 12px 2px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}.card-count{display:block;color:var(--muted);font-size:12px;padding:0 12px 12px}.card:hover{filter:brightness(1.13)}.search-panel{padding:24px;max-width:700px}.search-panel h2{font-size:25px;margin:0 0 14px}.mobile-search{display:none}.map-wrap{position:relative;margin:10px 24px 24px;aspect-ratio:2;background:radial-gradient(circle at 50% 40%,#1b3442,#12212a 72%);border:1px solid var(--line);border-radius:14px;overflow:hidden}.map-grid{position:absolute;inset:0;width:100%;height:100%;opacity:.34}.map-point{position:absolute;transform:translate(-50%,-50%);width:20px;height:20px;border:3px solid white;border-radius:50%;background:#418dff;box-shadow:0 2px 8px #000a;z-index:1}.map-point:hover{width:26px;height:26px;z-index:2}.map-note{padding:0 24px;color:var(--muted)}
        .viewer{display:none;position:fixed;inset:0;z-index:20;background:#080809;color:#fff}.viewer.open{display:flex}.viewer-main{position:relative;min-width:0;flex:1;display:flex;align-items:center;justify-content:center;padding:62px 58px 70px}.viewer-photo{display:flex;align-items:center;justify-content:center;max-width:100%;max-height:100%;border:0;padding:0;background:transparent;cursor:zoom-in}.viewer-image{display:block;max-width:100%;max-height:calc(100dvh - 132px);object-fit:contain}.viewer-top{position:absolute;top:0;left:0;right:0;height:58px;display:flex;align-items:center;justify-content:space-between;padding:0 18px;background:#171719e8;z-index:2}.viewer-close,.viewer-info-button{border:0;border-radius:8px;background:transparent;color:#fff;padding:8px 10px}.viewer-close{font-size:15px}.viewer-title{display:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.viewer-info-button{font-size:18px}.viewer-arrow{position:absolute;top:50%;transform:translateY(-50%);width:40px;height:50px;border:0;background:#1f1f22a8;color:#fff;font-size:30px;border-radius:8px}.viewer-arrow.prev{left:10px}.viewer-arrow.next{right:10px}.viewer-arrow:disabled{opacity:.25}.viewer-caption{position:absolute;bottom:0;left:0;right:0;min-height:54px;display:grid;place-content:center;text-align:center;background:#171719e8;font-size:13px}.viewer-caption small{color:#aaa;display:block;margin-top:3px}.viewer-info{width:290px;flex:none;border-left:1px solid var(--line);background:var(--surface);padding:78px 18px 24px;overflow:auto}.viewer-info h2{font-size:18px;margin:0 0 24px;overflow-wrap:anywhere}.meta-row{border-top:1px solid var(--line);padding:10px 0}.meta-row span{display:block;font-size:11px;color:var(--muted);margin-bottom:4px}.meta-row strong{font-size:13px;font-weight:500;overflow-wrap:anywhere}.viewer-info.closed{display:none}.viewer.expanded .viewer-main{padding:8px}.viewer.expanded .viewer-image{max-height:calc(100dvh - 16px)}.viewer.expanded .viewer-info,.viewer.expanded .viewer-caption,.viewer.expanded .viewer-info-button{display:none}.viewer.expanded .viewer-title{display:block}.viewer.expanded .viewer-top{gap:16px;background:transparent}.viewer.expanded .viewer-close{flex:none}
        .viewer-video{display:block;max-width:100%;max-height:calc(100dvh - 132px);background:#000}.viewer-live-video{position:absolute;inset:62px 58px 70px;width:calc(100% - 116px);height:calc(100% - 132px);object-fit:contain;z-index:1;pointer-events:none}.viewer-live-play{position:absolute;top:76px;left:72px;z-index:2;border:0;border-radius:999px;padding:7px 11px;background:#000a;color:#fff;font-size:12px;font-weight:650}.viewer-live-play:disabled{opacity:.65}.viewer-video-note{position:absolute;bottom:70px;left:12px;right:12px;text-align:center;color:#ddd;font-size:13px;pointer-events:none}.media-badge{position:absolute;bottom:8px;right:8px;z-index:1;display:inline-flex;align-items:center;gap:4px;padding:6px 8px;border-radius:999px;background:#000b;color:#fff;font-size:12px;font-weight:700;font-variant-numeric:tabular-nums;white-space:nowrap;pointer-events:none}.media-badge.icon-only{padding:6px 7px}.media-badge .live-symbol{font-size:14px;line-height:12px}.viewer-photo:disabled{cursor:default}
        .info-heading{text-align:center;font-size:16px;font-weight:650;margin-bottom:18px}.info-title-row{display:flex;align-items:start;gap:8px}.info-title{font-size:19px;overflow-wrap:anywhere;flex:1}.info-placeholder{font-style:italic;color:var(--muted)}.info-heart{font-size:22px;color:var(--muted)}.info-heart.favorite{color:#f45b6a}.info-filename,.info-date{margin-top:7px;overflow-wrap:anywhere}.info-date.empty{color:var(--muted)}.info-card{margin-top:18px;padding:12px;border-radius:14px;background:var(--bar);font-size:13px}.info-card-line{display:flex;align-items:center;flex-wrap:wrap;gap:5px 9px;margin-bottom:8px}.info-card-line:last-child{margin-bottom:0}.info-card-line .spacer{flex:1}.info-card-rule,.info-section{border-top:1px solid var(--line);margin-top:18px;padding-top:18px}.info-card-rule{margin:9px 0;padding:0}.info-metrics{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:3px;text-align:center;font-size:11px}.info-metrics span{overflow-wrap:anywhere}.info-format{font-size:10px;font-weight:700;background:var(--muted);color:var(--surface);border-radius:3px;padding:2px 5px}.info-live{font-size:16px;color:var(--muted);line-height:1}.info-map{height:260px;border-radius:12px;overflow:hidden;margin:12px 0}.info-coordinates{font-size:12px;color:var(--muted);overflow-wrap:anywhere}.info-coordinate-label{display:block;font-size:11px;margin-bottom:3px}.info-loading{color:var(--muted);font-size:12px}.viewer-info .meta-row{border:0;padding:4px 0;display:flex;justify-content:space-between;gap:8px}.viewer-info .meta-row span{font-size:12px;margin:0}.viewer-info .meta-row strong{text-align:right}
        .info-map-marker{color:#237af3;font-size:27px;line-height:1;text-shadow:0 1px 3px #fff,0 1px 5px #0008}.info-coordinates{white-space:pre-line}
        @media(min-width:701px) and (max-width:1050px){.sidebar{width:212px}.topbar{padding:0 15px;gap:9px}.page-heading{min-width:120px}.desktop-search{width:160px}.segment button{padding:6px 8px}.viewer-info{width:240px}}
        @media(max-width:700px){html,body{overflow:hidden}.sidebar,.topbar{display:none}.workspace{background:var(--grid)}.mobile-header{display:flex;flex:none;align-items:center;justify-content:space-between;gap:10px;min-height:58px;padding:10px 14px;background:var(--surface);border-bottom:1px solid var(--line)}.mobile-header strong{font-size:23px;letter-spacing:-.03em}.content-title{padding:18px 13px 12px;align-items:center}.content-title h1{font-size:21px}.count-label{font-size:11px}.grid{grid-template-columns:repeat(3,minmax(0,1fr));gap:1px}.tile-label{display:none}.content-inner{padding-bottom:105px}.mobile-timeline{display:flex;position:absolute;bottom:calc(67px + env(safe-area-inset-bottom));left:50%;transform:translateX(-50%);z-index:3;background:#28282cdd;backdrop-filter:blur(14px);padding:4px;border-radius:20px;box-shadow:0 3px 15px #0008}.mobile-timeline button{border:0;background:transparent;color:#c9c9ce;border-radius:16px;padding:7px 13px;font-size:12px;white-space:nowrap}.mobile-timeline button.active{background:#eee;color:#111}.bottom-nav{display:flex;position:absolute;bottom:0;left:0;right:0;z-index:4;height:calc(62px + env(safe-area-inset-bottom));padding-bottom:env(safe-area-inset-bottom);background:#242427ed;backdrop-filter:blur(16px);border-top:1px solid var(--line)}.bottom-nav button{display:grid;place-content:center;gap:2px;flex:1;border:0;background:transparent;color:#a8a8ae;font-size:10px}.bottom-nav button b{font-size:20px;line-height:22px;font-weight:400}.bottom-nav button.active{color:var(--accent)}.collection-section{padding:15px 13px 4px}.cards{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.cards.period-cards{grid-template-columns:repeat(2,minmax(0,1fr))}.card-cover{aspect-ratio:1}.search-panel{padding:17px 13px}.mobile-search{display:flex;background:#303034;border-radius:10px;padding:10px 12px;gap:8px;margin-bottom:18px}.map-wrap{margin:8px 12px 16px;aspect-ratio:.8}.map-note{padding:0 13px}.viewer-main{padding:64px 0 72px}.viewer-live-video{inset:64px 0 72px;width:100%;height:calc(100% - 136px)}.viewer-live-play{top:72px;left:12px}.viewer-top{padding:0 12px;background:transparent}.viewer-arrow{display:none}.viewer-info{display:none;position:absolute;bottom:0;left:0;right:0;width:100%;max-height:55%;z-index:3;border:0;border-radius:15px 15px 0 0;padding:20px 18px 35px;background:#242427ed;backdrop-filter:blur(18px)}.viewer-info.open-mobile{display:block}.viewer-info.closed{display:none}.viewer-caption{background:transparent;text-shadow:0 1px 6px #000}.status{padding-top:17vh}}
        @media(prefers-color-scheme:light){:root{color-scheme:light;color:#19191b;background:#fff;--surface:#f1f1f3;--bar:#f7f7f8;--hover:#e3e3e7;--line:#d8d8dd;--text:#19191b;--muted:#66666c;--accent:#1365c9;--grid:#fff}.segment{background:#dedee2}.segment button.active{background:#fff;color:#19191b}.desktop-search{background:#e8e8eb}.tile{background:#e9e9ed}.card-cover{background:#ddd}.zoom button:hover,.icon-button:hover{background:#ddd}.mobile-timeline{background:#e7e7eadb}.mobile-timeline button.active{background:#333;color:#fff}.bottom-nav{background:#f4f4f6ec}}
        .mobile-bottom-controls,.mobile-search-controls{display:none}
        @media(max-width:700px){
          .mobile-header{min-height:calc(72px + env(safe-area-inset-top));padding:calc(10px + env(safe-area-inset-top)) 16px 10px;background:var(--grid);border-bottom:0}
          .mobile-header strong{font-size:32px;font-weight:750}
          .mobile-filter-wrap,.mobile-library-wrap{position:relative;flex:none}
          .mobile-filter-button,.mobile-circle-button{display:grid;place-items:center;border:1px solid var(--line);background:var(--bar);color:var(--text);box-shadow:0 2px 12px #0004;backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px)}
          .mobile-filter-button{display:flex;align-items:center;gap:6px;min-height:44px;border-radius:25px;padding:0 13px;font-size:14px;font-weight:600}
          .mobile-filter-button svg{width:20px;height:20px}
          .mobile-circle-button{width:54px;height:54px;border-radius:50%;padding:0;color:var(--accent)}
          .mobile-circle-button svg{width:27px;height:27px}
          .mobile-bottom-controls{display:flex;position:absolute;z-index:4;bottom:calc(10px + env(safe-area-inset-bottom));left:0;right:0;align-items:center;justify-content:space-between;gap:10px;padding:0 14px;pointer-events:none}
          .mobile-bottom-controls>*{pointer-events:auto}
          .app.search-mode .mobile-bottom-controls,.app.search-mode .mobile-filter-wrap{display:none}
          .mobile-search-controls{display:flex;position:fixed;z-index:5;bottom:calc(10px + var(--mobile-search-safe-inset, env(safe-area-inset-bottom)) + var(--mobile-search-keyboard-offset, 0px));left:0;right:0;align-items:center;gap:8px;padding:0 14px}
          .mobile-search-controls .mobile-search{display:flex;align-items:center;flex:1;min-width:0;min-height:54px;margin:0;padding:0 16px;gap:10px;border:1px solid var(--line);border-radius:30px;background:var(--bar);color:var(--text);box-shadow:0 2px 12px #0004}
          .mobile-search-controls .mobile-search input{font-size:16px}
          .mobile-search-controls .mobile-search-icon{flex:none;width:21px;height:21px}
          .mobile-search-controls .mobile-circle-button{flex:none;color:var(--text)}
          .mobile-timeline{display:flex;position:relative;bottom:auto;left:auto;transform:none;min-width:0;flex:1;justify-content:space-around;gap:0;padding:4px;border:1px solid var(--line);border-radius:30px;background:var(--bar);box-shadow:0 2px 12px #0004}
          .mobile-timeline button{min-width:0;flex:1;padding:13px 2px;border-radius:25px;font-size:13px;font-weight:600}
          .bottom-nav{display:none}
          .content-inner{padding-bottom:calc(90px + env(safe-area-inset-bottom))}
          .grid,.map-photo-grid{grid-template-columns:repeat(5,minmax(0,1fr));gap:2px;padding:2px}
          .media-badge{bottom:3px;right:3px;padding:3px 4px;font-size:9px}
          .media-badge.icon-only{padding:3px 4px}
          .mobile-menu{position:absolute;z-index:10;min-width:170px;padding:7px;border:1px solid var(--line);border-radius:16px;background:var(--bar);box-shadow:0 8px 30px #0008;backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px)}
          .mobile-menu button{display:block;width:100%;min-height:42px;padding:9px 12px;border:0;border-radius:10px;background:transparent;color:var(--text);text-align:left;font-size:15px}
          .mobile-menu button:hover,.mobile-menu button:focus-visible{background:var(--hover)}
          .mobile-filter-menu{top:calc(100% + 8px);right:0;max-height:65dvh;overflow-y:auto}
          .mobile-menu-heading{padding:9px 12px 3px;color:var(--muted);font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.06em}
          .mobile-library-menu{bottom:calc(100% + 9px);left:0}
        }
        .page-heading,.mobile-page-heading{display:flex;flex-direction:column;justify-content:center}.mobile-page-heading{min-width:0}.page-heading #desktop-title,.mobile-page-heading #mobile-title{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.toolbar-subtitle{font-size:11px;font-weight:400;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.content.memories-mode .content-title{display:none}.memory-cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:18px;padding:20px 24px}.memory-card{min-width:0;border:0;background:transparent;color:var(--text);text-align:left;padding:0}.memory-card-cover{display:block;position:relative;height:190px;border-radius:10px;overflow:hidden;background:var(--surface)}.memory-card-cover img{display:block;width:100%;height:100%;object-fit:cover}.memory-card-title{display:block;margin-top:9px;font-size:16px;font-weight:650;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}.memory-card-subtitle{display:block;margin-top:5px;color:var(--muted);font-size:12px}.memory-card:hover .memory-card-cover,.memory-card:focus-visible .memory-card-cover{outline:2px solid var(--accent)}.memory-photo-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(145px,1fr));gap:3px;padding:12px}.memory-photo-grid .tile{border-radius:5px}.memory-controls{position:absolute;right:20px;bottom:26px;z-index:3;display:flex;align-items:center;gap:10px;border-radius:22px;padding:6px 10px;background:#18181bdd;color:white}.memory-controls button{border:0;border-radius:16px;padding:6px 10px;background:#ffffff24;color:white}.memory-controls span{font-size:12px}.memory-controls[hidden]{display:none}
        .memory-toolbar-button{display:inline-flex;align-items:center;justify-content:center;gap:7px;min-height:36px;padding:7px 9px;border:0;border-radius:7px;background:transparent;color:var(--text);font:inherit;font-size:13px;font-weight:500;white-space:nowrap;cursor:pointer}.memory-toolbar-button svg{width:17px;height:17px;flex:none}.memory-toolbar-button[hidden]{display:none}.memory-toolbar-button:hover:not(:disabled){background:var(--hover)}.memory-toolbar-button:disabled{opacity:.45;cursor:default}.memory-toolbar-button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}.memory-toolbar-play{color:var(--accent)}
        @media(min-width:701px) and (max-width:1050px){.memory-toolbar-button span{display:none}}
        @media(max-width:700px){.memory-toolbar-button{width:40px;height:40px;min-height:40px;padding:8px}.memory-toolbar-button svg{width:20px;height:20px}.memory-toolbar-button span{display:none}.app.memory-detail .mobile-filter-wrap{display:none}.app.memory-detail .mobile-page-heading{flex:1}.app.memory-detail .mobile-header strong{font-size:20px}}
        .viewer:fullscreen{width:100%;height:100%;background:#000}.viewer:fullscreen .viewer-info,.viewer:fullscreen .viewer-caption,.viewer:fullscreen .viewer-info-button{display:none}.viewer:fullscreen .viewer-main{padding:0}.viewer:fullscreen .viewer-image,.viewer:fullscreen .viewer-video{max-width:100vw;max-height:100dvh;object-fit:contain}.viewer:fullscreen .viewer-live-video{inset:0;width:100%;height:100dvh}.viewer:fullscreen .viewer-top{background:linear-gradient(#0009,transparent)}.viewer:fullscreen .viewer-arrow{z-index:3}.viewer:fullscreen .memory-controls{bottom:22px}
        @media(max-width:700px){.memory-cards{grid-template-columns:repeat(2,minmax(0,1fr));gap:13px;padding:12px}.memory-card-cover{height:auto;aspect-ratio:1.2}.memory-card-title{font-size:14px}.memory-photo-grid{grid-template-columns:repeat(3,minmax(0,1fr));padding:3px}.memory-controls{right:12px;bottom:72px}}
        .viewer-info{color:var(--text);user-select:text;-webkit-user-select:text}
        @media(max-width:700px){.viewer-info{background:var(--surface)}}
        @media(prefers-reduced-motion:reduce){*,*:before,*:after{transition:none!important;scroll-behavior:auto!important}}
        .content.map-mode{overflow:hidden}.content.map-mode .content-inner{height:100%;min-height:0;padding:0}.content.map-mode .content-title{display:none}#map-content:not([hidden]){position:relative;height:100%;min-height:0}.map-pane{position:absolute;inset:0}.map-pane.map-covered{opacity:0;pointer-events:none}.map-wrap{width:100%;height:100%;margin:0;border:0;border-radius:0;background:var(--surface)}.map-photo-pane{position:absolute;inset:0;display:flex;flex-direction:column;background:var(--grid)}.map-photo-header{display:flex;align-items:center;gap:14px;min-height:64px;padding:10px 16px;background:var(--bar);border-bottom:1px solid var(--line)}.map-back{border:0;background:none;color:var(--accent);padding:8px 2px}.map-photo-heading{font-weight:650}.map-photo-count{font-size:12px;color:var(--muted);margin-top:2px}.map-photo-scroll{overflow:auto;min-height:0;flex:1}.map-photo-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:1px;padding:1px}.map-photo-tile{display:block;position:relative;aspect-ratio:1;border:0;padding:0;background:#29292d;overflow:hidden}.map-photo-tile img{display:block;width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity .18s}.map-photo-tile img.loaded{opacity:1}.map-photo-tile .placeholder{font-size:20px}.map-photo-tile:focus-visible{outline:3px solid var(--accent);outline-offset:-3px}
        .app.map-fullscreen .sidebar,.app.map-fullscreen .topbar,.app.map-fullscreen .mobile-header,.app.map-fullscreen .bottom-nav,.app.map-fullscreen .mobile-timeline,.app.map-fullscreen .mobile-bottom-controls{display:none!important}.app.map-fullscreen .workspace{width:100%;height:100%}.app.map-fullscreen .content{height:100%}.map-exit{position:fixed;top:calc(12px + env(safe-area-inset-top));left:calc(12px + env(safe-area-inset-left));z-index:10;border:1px solid #ffffff55;border-radius:10px;padding:9px 13px;background:#242427dc;color:white;box-shadow:0 2px 12px #0005;backdrop-filter:blur(12px)}.map-exit:focus-visible{outline:3px solid var(--accent)}
        .sidebar-toggle{flex:none;display:grid;place-items:center}.sidebar-toggle svg{display:block;width:20px;height:20px}@media(max-width:700px){.sidebar-toggle{display:none}}
        #gallery.panorama-list{display:flex;flex-direction:column;gap:16px;padding:12px 24px;background:transparent}
        #gallery.panorama-list .tile{width:100%;height:235px;aspect-ratio:auto;border-radius:7px}
        #gallery.panorama-list .tile img{object-fit:cover}
        @media(max-width:700px){#gallery.panorama-list{gap:12px;padding:8px 12px}}
        .photo-map-marker{width:68px;height:78px;display:flex;flex-direction:column;align-items:center;gap:2px;cursor:pointer}.photo-map-count{min-width:22px;height:20px;display:grid;place-items:center;padding:0 7px;border-radius:11px;background:#000c;color:white;font-size:11px;font-weight:700;line-height:20px}.photo-map-image{position:relative;width:54px;height:54px;overflow:hidden;border:3px solid white;border-radius:8px;background:#38383d;box-shadow:0 2px 7px #0007}.photo-map-image img{display:block;width:100%;height:100%;object-fit:cover;opacity:0}.photo-map-image img.loaded{opacity:1}.photo-map-image .placeholder{font-size:16px}.photo-map-image .media-badge{bottom:2px;right:2px;gap:2px;padding:2px 4px;font-size:9px}.photo-map-image .media-badge.icon-only{padding:2px 4px}.photo-map-image .media-badge .live-symbol{font-size:10px;line-height:9px}.photo-map-marker.selected .photo-map-count{background:#3379d8}.photo-map-marker.selected .photo-map-image{border-color:#3379d8}
        @media(max-width:700px){.map-photo-header{min-height:56px;padding:8px 12px}.map-photo-grid{grid-template-columns:repeat(5,minmax(0,1fr));gap:2px;padding:2px}}
      </style>
    </head>
    <body>
      <div class="app">
        <aside class="sidebar" id="desktop-sidebar" aria-label="相片圖庫導覽"><div class="sidebar-brand"><span class="brand-icon" aria-hidden="true">✿</span>Photo Libraries</div><div class="side-heading">瀏覽</div><button class="side-link" id="nav-all" type="button"><span class="side-icon">▦</span>所有圖庫</button><button class="side-link" id="nav-memories" type="button"><span class="side-icon">✦</span>Memories</button><button class="side-link" id="nav-map" type="button"><span class="side-icon">◎</span>地圖</button><div class="side-heading">已分享圖庫</div><div id="library-links"></div><div class="side-heading" id="album-heading" hidden>相簿</div><div id="album-links"></div><div class="side-heading">Media Types</div><button class="side-link" id="nav-videos" type="button"><span class="side-icon">▶</span>Videos</button><div id="media-links"></div></aside>
        <div class="workspace"><header class="topbar"><button id="sidebar-toggle" class="icon-button sidebar-toggle" type="button" aria-label="隱藏側邊欄" aria-controls="desktop-sidebar" aria-expanded="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2"></rect><path d="M9 4v16"></path></svg></button><button id="desktop-memory-back" class="memory-toolbar-button" type="button" aria-label="返回 Memories" title="返回 Memories" hidden><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 12H5m7-7-7 7 7 7"/></svg><span>返回 Memories</span></button><div class="page-heading"><span id="desktop-title">所有圖庫</span><span id="desktop-subtitle" class="toolbar-subtitle" hidden></span></div><div class="toolbar-center"><div class="zoom" aria-label="縮圖大小"><button id="zoom-out" type="button" aria-label="縮小縮圖">−</button><button id="zoom-in" type="button" aria-label="放大縮圖">＋</button></div><div class="segment" role="group" aria-label="時間瀏覽"><button data-period="years" type="button">年份</button><button data-period="months" type="button">月份</button><button data-period="all" type="button">所有相片</button></div></div><label class="desktop-search"><span aria-hidden="true">⌕</span><input id="desktop-query" type="search" placeholder="搜尋相片" aria-label="搜尋相片"></label><button id="desktop-memory-play" class="memory-toolbar-button memory-toolbar-play" type="button" aria-label="Play Memory" title="Play Memory" hidden><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M7 4.5a1 1 0 0 1 1.53-.85l11 7.5a1 1 0 0 1 0 1.7l-11 7.5A1 1 0 0 1 7 19.5z"/></svg><span>Play Memory</span></button></header>
          <header class="mobile-header"><button id="mobile-memory-back" class="memory-toolbar-button" type="button" aria-label="返回 Memories" title="返回 Memories" hidden><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 12H5m7-7-7 7 7 7"/></svg><span>返回 Memories</span></button><div class="mobile-page-heading"><strong id="mobile-title">Library</strong><span id="mobile-subtitle" class="toolbar-subtitle" hidden></span></div><div class="mobile-filter-wrap"><button id="mobile-filter-button" class="mobile-filter-button" type="button" aria-label="Filter" aria-controls="mobile-filter-menu" aria-expanded="false"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M3 6h18M6 12h12M9 18h6"></path></svg><span>Filter</span></button><div id="mobile-filter-menu" class="mobile-menu mobile-filter-menu" hidden><button type="button" data-mobile-filter="map">Map</button><div class="mobile-menu-heading">Media Types</div><button type="button" data-mobile-filter="videos">Videos</button><div id="mobile-media-links"></div></div></div><button id="mobile-memory-play" class="memory-toolbar-button memory-toolbar-play" type="button" aria-label="Play Memory" title="Play Memory" hidden><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M7 4.5a1 1 0 0 1 1.53-.85l11 7.5a1 1 0 0 1 0 1.7l-11 7.5A1 1 0 0 1 7 19.5z"/></svg><span>Play Memory</span></button></header>
          <main id="content" class="content"><div class="content-inner"><div class="content-title"><div><button id="back-period" class="back-button" type="button" hidden>‹ 返回</button><h1 id="section-title">所有圖庫</h1><p class="subline" id="section-subtitle"></p></div><span id="count-label" class="count-label"></span></div><div id="load-row" class="load-row" hidden><button id="load-more" class="load-button" type="button">載入較早相片</button></div><section id="gallery" class="grid" aria-label="相片"></section><div id="collections-content" hidden></div><div id="memories-content" hidden></div><div id="map-content" hidden></div><div id="search-intro" class="search-panel" hidden><h2 id="search-heading">搜尋相片</h2><p class="subline">可按檔名、日期及現有相片資料搜尋。</p></div><div id="status" class="status" hidden></div></div></main><button id="map-exit" class="map-exit" type="button" hidden>‹ 返回</button>
          <div id="mobile-search-controls" class="mobile-search-controls" role="search" hidden><label class="mobile-search"><svg class="mobile-search-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="10.8" cy="10.8" r="6.8"></circle><path d="m16 16 5 5"></path></svg><input id="mobile-query" type="search" placeholder="搜尋相片" aria-label="搜尋相片"></label><button id="mobile-search-close" class="mobile-circle-button" type="button" aria-label="關閉搜尋"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M5 5l14 14M19 5 5 19"></path></svg></button></div>
          <nav class="mobile-bottom-controls" aria-label="主要導覽"><div class="mobile-library-wrap"><button id="mobile-library-button" class="mobile-circle-button" type="button" aria-label="選擇圖庫或 Albums" aria-controls="mobile-library-menu" aria-expanded="false"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2.5" y="5" width="19" height="15" rx="2"></rect><path d="M7 5V3h10v2M6 16l4-4 3 3 2-2 3 3"></path></svg></button><div id="mobile-library-menu" class="mobile-menu mobile-library-menu" hidden><div id="mobile-library-choices"></div><button type="button" data-mobile-destination="albums">Albums</button><button type="button" data-mobile-destination="memories">Memories</button></div></div><div class="mobile-timeline" id="mobile-timeline" role="group" aria-label="時間瀏覽"><button data-period="years" type="button">Years</button><button data-period="months" type="button">Months</button><button data-period="all" type="button">All</button></div><button id="mobile-search-button" class="mobile-circle-button" type="button" aria-label="搜尋相片"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="10.8" cy="10.8" r="6.8"></circle><path d="m16 16 5 5"></path></svg></button></nav>
        </div>
      </div>
          <div id="viewer" class="viewer" role="dialog" aria-modal="true" aria-label="相片預覽" aria-hidden="true"><div class="viewer-main" id="viewer-main"><div class="viewer-top"><button id="viewer-close" class="viewer-close" type="button">‹ 返回相片</button><span id="viewer-title" class="viewer-title"></span><button id="viewer-info-toggle" class="viewer-info-button" type="button" aria-label="顯示相片資訊">ⓘ</button></div><button class="viewer-arrow prev" id="viewer-prev" type="button" aria-label="上一張">‹</button><button id="viewer-photo" class="viewer-photo" type="button" aria-label="放大相片"><img id="viewer-image" class="viewer-image" alt=""></button><video id="viewer-live-video" class="viewer-live-video" playsinline preload="none" hidden></video><button id="viewer-live-play" class="viewer-live-play" type="button" hidden>◎ Live</button><video id="viewer-video" class="viewer-video" controls playsinline preload="metadata" hidden></video><div id="viewer-video-note" class="viewer-video-note" hidden></div><button class="viewer-arrow next" id="viewer-next" type="button" aria-label="下一張">›</button><div id="viewer-caption" class="viewer-caption"></div><div id="memory-controls" class="memory-controls" hidden><button id="memory-pause" type="button" aria-label="暫停回憶播放">暫停</button><span id="memory-progress"></span></div></div><aside id="viewer-info" class="viewer-info" aria-label="相片資訊"></aside></div>
      <script>
      (()=>{
        'use strict';
        const $=id=>document.getElementById(id), pageSize=80;
        const gallery=$('gallery'), status=$('status'), content=$('content'), viewer=$('viewer'), viewerImage=$('viewer-image'), viewerVideo=$('viewer-video'), viewerLiveVideo=$('viewer-live-video'), viewerLivePlay=$('viewer-live-play');
        const mediaTypes=[{id:'videos',title:'Videos'},{id:'selfies',title:'Selfies'},{id:'livePhotos',title:'Live Photos'},{id:'portrait',title:'Portrait'},{id:'panoramas',title:'Panoramas'},{id:'timeLapse',title:'Time-lapse'},{id:'sloMo',title:'Slo-mo'},{id:'cinematic',title:'Cinematic'},{id:'bursts',title:'Bursts'}];
        const mediaIcons={
          videos:'<rect x="2" y="5" width="15" height="14" rx="2"/><path d="m17 9 5-3v12l-5-3z"/>',
          selfies:'<rect x="4" y="3" width="16" height="18" rx="2"/><circle cx="12" cy="10" r="2.5"/><path d="M7.5 18c.6-2.4 2.1-3.6 4.5-3.6s3.9 1.2 4.5 3.6"/>',
          livePhotos:'<circle cx="12" cy="12" r="3"/><circle cx="12" cy="12" r="6.5"/><path d="M12 1.5v1.3M12 21.2v1.3M1.5 12h1.3M21.2 12h1.3M4.5 4.5l.9.9M18.6 18.6l.9.9M19.5 4.5l-.9.9M5.4 18.6l-.9.9"/>',
          portrait:'<circle cx="12" cy="12" r="9"/><path d="M15 7.3c-2.5-.7-3.3.8-3.5 3.2l-.6 7M8.5 12h6.1"/>',
          panoramas:'<path d="M3 5.5c5.5 2.5 12.5 2.5 18 0v13c-5.5-2.5-12.5-2.5-18 0z"/>',
          timeLapse:'<circle cx="12" cy="12" r="9" stroke-dasharray="1 2.3"/><path d="M12 7v5l3.3 2"/>',
          sloMo:'<circle cx="12" cy="12" r="2"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M19.1 4.9 17 7M7 17l-2.1 2.1M8.2 2.8l.7 2.4M15.1 18.8l.7 2.4M2.8 15.8l2.4-.7M18.8 8.9l2.4-.7"/>',
          cinematic:'<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8" cy="12" r="2.2"/><path d="m13 9 4 3-4 3z"/>',
          bursts:'<path d="M5 6.5 15 2v15.5L5 22zM9 6l10-4v15.5l-4 1.7"/>'
        };
        const mediaIcon=id=>'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+mediaIcons[id]+'</svg>';
        $('nav-videos').querySelector('.side-icon').innerHTML=mediaIcon('videos');
        const mediaTitle=id=>mediaTypes.find(type=>type.id===id)?.title||'相片';
        let memories=[], selectedMemory=null, memorySlideshow=false, memoryPaused=false, memoryFullscreenActive=false, memoryTimer=null, memoryPauseHideTimer=null, memoryRemaining=2000, memoryStarted=0, previousTrack=null, memoryMusicFailed=false;const memoryMusic=new Audio();memoryMusic.loop=true;memoryMusic.volume=.45;let libraries=[], collections=null, library='all', view='library', mediaCategory=null, searchCategory=null, mapReturnView='library', mapReturnCategory=null, period='all', filterYear=null, filterMonth=null, album=null, albumTitle='', search='', searchVideosOnly=false, searchReturnState=null, items=[], total=0, offset=0, loading=false, loadPromise=null, initialScrollPending=false, generation=0, request=null, selected=-1, viewerItems=[], previousFocus=null, zoom=140, mapItems=[], appleMap=null, mapKitPromise=null, mapKitErrorHandlerBound=false;
        const viewStorageKey='photo-libraries-web-gallery-view-v1';let persistenceReady=false,restoringScroll=false,saveTimer=null,lastScrollTop=0;
        function savedView(){try{const value=JSON.parse(localStorage.getItem(viewStorageKey));return value&&typeof value==='object'&&value.version===1?value:null}catch(_){return null}}
        function persistView(){if(!persistenceReady||restoringScroll)return;const previous=savedView();const state=view==='search'?(searchReturnState||previous||{view:'library',library:'all',period:'all'}):{view,library,mediaCategory,period,filterYear,filterMonth,album,scrollFromBottom:Math.max(0,content.scrollHeight-content.clientHeight-content.scrollTop)};try{localStorage.setItem(viewStorageKey,JSON.stringify({version:1,view:state.view,library:state.library,mediaCategory:state.mediaCategory||null,period:state.period||'all',filterYear:state.filterYear||null,filterMonth:state.filterMonth||null,album:state.album||null,scrollFromBottom:view==='search'?previous?.scrollFromBottom||0:state.scrollFromBottom,zoom,sidebarExpanded:!$('desktop-sidebar').hidden}))}catch(_){}}
        function scheduleSave(){if(!persistenceReady||restoringScroll)return;clearTimeout(saveTimer);saveTimer=setTimeout(persistView,180)}
        content.addEventListener('scroll',()=>{const position=Math.max(0,content.scrollTop),scrollingUp=position<lastScrollTop;lastScrollTop=position;scheduleSave();if(scrollingUp)maybeLoadOlder()},{passive:true});window.addEventListener('pagehide',()=>{clearTimeout(saveTimer);persistView()});
        const queue=[], jobs=new WeakMap();let activeImages=0,imageGeneration=0;
        const imageObserver=new IntersectionObserver(entries=>{for(const entry of entries){if(!entry.isIntersecting)continue;imageObserver.unobserve(entry.target);const job=jobs.get(entry.target);if(job)queue.push(job)}runImages()},{rootMargin:'450px'});
        function observeThumbnailJobs(hosts){for(const host of hosts)if(jobs.has(host))imageObserver.observe(host)}
        function maybeLoadOlder(){if(restoringScroll||loading||initialScrollPending||!items.length||offset>=total||content.scrollTop>600)return;loadItems()}
        function imageIsVisible(job){const rect=job.img.getBoundingClientRect(),viewport=content.getBoundingClientRect();return rect.bottom>viewport.top&&rect.top<viewport.bottom&&rect.right>viewport.left&&rect.left<viewport.right}
        function runImages(){while(activeImages<6&&queue.length){const visibleIndex=queue.findIndex(job=>job.generation===imageGeneration&&job.img.isConnected&&imageIsVisible(job));const job=visibleIndex<0?queue.shift():queue.splice(visibleIndex,1)[0];if(job.generation!==imageGeneration||!job.img.isConnected)continue;activeImages++;const done=()=>{job.img.onload=null;job.img.onerror=null;if(job.generation===imageGeneration){activeImages--;runImages()}};job.img.onload=()=>{job.img.classList.add('loaded');job.placeholder.remove();done()};job.img.onerror=()=>{done();if(job.generation!==imageGeneration||!job.img.isConnected)return;if(job.attempt++<2){setTimeout(()=>{if(job.generation===imageGeneration&&job.img.isConnected){queue.push(job);runImages()}},job.attempt*500)}else{job.img.remove();job.placeholder.textContent='預覽暫不可用'}};job.img.src=job.url}}
        function resetImages(){imageGeneration++;imageObserver.disconnect();queue.length=0;activeImages=0}
        function imageURL(item,size){return '/api/image?'+new URLSearchParams({library:item.library,id:item.id,size})}
        function videoURL(item,live=false){const params=new URLSearchParams({library:item.library,id:item.id});if(live)params.set('live','1');return '/api/video?'+params}
        function videoDuration(seconds){if(!Number.isFinite(seconds)||seconds<=0)return '';const total=Math.round(seconds),minutes=Math.floor(total/60),part=String(total%60).padStart(2,'0');return minutes>=60?`${Math.floor(minutes/60)}:${String(minutes%60).padStart(2,'0')}:${part}`:`${minutes}:${part}`}
        function mediaBadge(item){
            const isVideo=item.mediaType==='video';
            if(!isVideo&&!item.isLivePhoto)return null;
            const badge=document.createElement('span');badge.className='media-badge';badge.setAttribute('aria-hidden','true');
            if(isVideo){const duration=videoDuration(item.duration);badge.textContent=duration?`▶ ${duration}`:'▶';if(!duration)badge.classList.add('icon-only')}
            else{badge.classList.add('icon-only');const symbol=document.createElement('span');symbol.className='live-symbol';symbol.textContent='◎';badge.append(symbol)}
            return badge
        }
        function appendMediaBadge(item,host){const badge=mediaBadge(item);if(badge)host.append(badge)}
        async function json(path,signal){const response=await fetch(path,{headers:{Accept:'application/json'},signal});if(!response.ok)throw new Error(String(response.status));return response.json()}
        function nameFor(id){return id==='all'?'所有圖庫':libraries.find(l=>l.id===id)?.name||'相片圖庫'}
        function showStatus(title,message,retry){gallery.replaceChildren();$('collections-content').hidden=true;$('memories-content').hidden=true;$('map-content').hidden=true;$('load-row').hidden=true;status.hidden=false;status.replaceChildren();const h=document.createElement('h2');h.textContent=title;const p=document.createElement('p');p.textContent=message;status.append(h,p);if(retry){const b=document.createElement('button');b.type='button';b.textContent='重試';b.onclick=retry;status.append(b)}}
        function clearStatus(){status.hidden=true;status.replaceChildren()}
        function dateLabel(item){if(!item.date)return '';const d=new Date(item.date);return Number.isNaN(d.valueOf())?'':new Intl.DateTimeFormat('zh-Hant',{year:'numeric',month:'long',day:'numeric'}).format(d)}
        function safeTitle(item){return item.title||item.filename||'相片'}
        function renderHeader(){let title=nameFor(library),subtitle='';if(view==='memories'){title=selectedMemory?.title||'Memories';subtitle=selectedMemory?.dateRange||'已分享圖庫'}else if(view==='map'){title='地圖';subtitle='已分享相片的位置'}else if(view==='videos'||view==='media'){title=mediaTitle(view==='videos'?'videos':mediaCategory);subtitle='所有已分享圖庫'}else if(view==='search'){title=searchVideosOnly?'搜尋影片':searchCategory?`搜尋 ${mediaTitle(searchCategory)}`:'搜尋';subtitle=search?'搜尋結果':'在已分享圖庫中搜尋'}else if(view==='collections'){title='選集';subtitle=nameFor(library)}else if(view==='albums'){title='Albums';subtitle=nameFor(library)}else if(album){title=albumTitle||'相簿';subtitle=nameFor(library)}else if(filterYear){title=filterMonth?`${filterYear} 年 ${filterMonth} 月`:`${filterYear} 年`;subtitle=nameFor(library)}else if(period==='years'){title='年份';subtitle=nameFor(library)}else if(period==='months'){title='月份';subtitle=nameFor(library)}$('desktop-title').textContent=title;$('section-title').textContent=title;$('section-subtitle').textContent=subtitle;$('mobile-title').textContent=view==='library'?'Library':view==='albums'?'Albums':view==='videos'?'Videos':view==='media'?mediaTitle(mediaCategory):view==='collections'?'選集':view==='memories'?title:view==='search'?'Search':'Map';$('back-period').hidden=!(filterYear||album);$('count-label').textContent=(view==='library'&&period==='all'||view==='videos'||view==='media')&&total?`${total.toLocaleString()} ${view==='videos'||view==='media'&&['timeLapse','sloMo','cinematic'].includes(mediaCategory)?'段':'張'}`:'';document.querySelectorAll('[data-period]').forEach(b=>b.classList.toggle('active',view==='library'&&b.dataset.period===period));document.querySelectorAll('[data-tab]').forEach(b=>b.classList.toggle('active',b.dataset.tab===(view==='map'?'collections':view)));$('mobile-timeline').hidden=view==='videos'||view==='media'||view==='memories';for(const id of ['desktop-subtitle','mobile-subtitle']){const heading=$(id);heading.textContent=view==='memories'?subtitle:'';heading.hidden=view!=='memories'}const memoryDetail=view==='memories'&&!!selectedMemory;document.querySelector('.app').classList.toggle('memory-detail',memoryDetail);for(const id of ['desktop-memory-back','mobile-memory-back'])$(id).hidden=!memoryDetail;for(const id of ['desktop-memory-play','mobile-memory-play']){const button=$(id);button.hidden=!memoryDetail;button.disabled=!selectedMemory?.items.length}}
        function renderSidebar(){const list=$('library-links');list.replaceChildren();const all=$('nav-all');all.classList.toggle('active',library==='all'&&view==='library'&&!album);$('nav-map').classList.toggle('active',view==='map');$('nav-memories').classList.toggle('active',view==='memories');$('nav-videos').classList.toggle('active',view==='videos');for(const [hostID,mobile] of [['media-links',false],['mobile-media-links',true]]){const host=$(hostID);host.replaceChildren();for(const type of mediaTypes.slice(1)){const b=document.createElement('button');b.type='button';if(mobile){b.textContent=type.title;if(view==='media'&&mediaCategory===type.id)b.setAttribute('aria-current','page')}else{b.className='side-link'+(view==='media'&&mediaCategory===type.id?' active':'');const icon=document.createElement('span');icon.className='side-icon';icon.innerHTML=mediaIcon(type.id);const label=document.createElement('span');label.textContent=type.title;b.append(icon,label)}b.onclick=()=>{closeMobileMenus();openMedia(type.id)};host.append(b)}}for(const lib of libraries){const b=document.createElement('button');b.type='button';b.className='side-link'+(lib.id===library&&view==='library'&&!album?' active':'');const icon=document.createElement('span');icon.className='side-icon';icon.textContent=lib.kind==='system'?'▧':'▦';const label=document.createElement('span');label.textContent=lib.name;label.style.cssText='overflow:hidden;text-overflow:ellipsis;white-space:nowrap';const count=document.createElement('span');count.className='side-count';count.textContent=Number(lib.count||0).toLocaleString();b.append(icon,label,count);b.onclick=()=>chooseLibrary(lib.id);list.append(b)}const albums=$('album-links');albums.replaceChildren();$('album-heading').hidden=library==='all'||!(collections?.albums?.length)||view==='videos'||view==='media';if(library!=='all'&&view!=='videos'&&view!=='media')for(const a of sortedAlbums(collections?.albums||[])){const b=document.createElement('button');b.type='button';b.className='album-link'+(album===a.id?' active':'');b.textContent=a.parent?`${a.parent} / ${a.title}`:a.title;b.onclick=()=>openAlbum(a);albums.append(b)}const choices=$('mobile-library-choices');choices.replaceChildren();const systemLibrary=libraries.find(l=>l.kind==='system'),secondLibrary=libraries.find(l=>l.kind!=='system');const entries=[{id:'all',name:'All Libraries'}];if(systemLibrary)entries.push({id:systemLibrary.id,name:'Photo Library'});if(secondLibrary)entries.push({id:secondLibrary.id,name:'Photo Library 2'});for(const lib of libraries)if(lib!==systemLibrary&&lib!==secondLibrary)entries.push({id:lib.id,name:lib.name});for(const entry of entries){const b=document.createElement('button');b.type='button';b.textContent=entry.name;if(view==='library'&&library===entry.id)b.setAttribute('aria-current','page');b.onclick=()=>{closeMobileMenus();chooseLibrary(entry.id)};choices.append(b)}}
        function resetList(){clearTimeout(searchTimer);if(request)request.abort();request=null;if(appleMap){appleMap.destroy();appleMap=null}generation++;resetImages();mapItems=[];items=[];offset=0;total=0;loading=false;loadPromise=null;initialScrollPending=false;gallery.replaceChildren();$('map-content').replaceChildren();$('memories-content').replaceChildren();$('load-row').hidden=true;clearStatus();lastScrollTop=0;content.scrollTop=0}
        function setVisibility(){const list=view==='library'&&period==='all'||view==='videos'||view==='media'||view==='search'&&!!search;$('gallery').hidden=!list;gallery.classList.toggle('panorama-list',view==='media'&&mediaCategory==='panoramas'||view==='search'&&searchCategory==='panoramas');$('gallery').setAttribute('aria-label',view==='videos'||view==='search'&&searchVideosOnly?'影片':view==='media'?mediaTitle(mediaCategory):'相片');$('collections-content').hidden=!(view==='collections'||view==='albums'||view==='library'&&period!=='all');$('map-content').hidden=view!=='map';$('memories-content').hidden=view!=='memories';content.classList.toggle('map-mode',view==='map');content.classList.toggle('memories-mode',view==='memories');document.querySelector('.app').classList.toggle('map-fullscreen',view==='map');document.querySelector('.app').classList.toggle('search-mode',view==='search');$('map-exit').hidden=view!=='map';$('mobile-search-controls').hidden=view!=='search';document.querySelector('.topbar .segment').hidden=view==='videos'||view==='media'||view==='memories';document.querySelector('.topbar .zoom').hidden=view==='memories';$('search-intro').hidden=view!=='search';$('search-heading').textContent=searchVideosOnly?'搜尋影片':searchCategory?`搜尋 ${mediaTitle(searchCategory)}`:'搜尋相片';$('desktop-query').placeholder=searchVideosOnly||view==='videos'?'搜尋影片':view==='media'?`搜尋 ${mediaTitle(mediaCategory)}`:searchCategory?`搜尋 ${mediaTitle(searchCategory)}`:'搜尋相片';$('mobile-query').placeholder=$('desktop-query').placeholder;$('desktop-query').value=search;$('mobile-query').value=search;renderHeader();renderSidebar();scheduleSave()}
        async function fetchCollections(){const token=generation,selectedLibrary=library;try{const data=await json('/api/collections?'+new URLSearchParams({library:selectedLibrary}));if(token!==generation||selectedLibrary!==library)return;collections=data;if(view==='collections'||view==='albums'||period!=='all')renderCollections();renderSidebar()}catch(_){if(token!==generation||selectedLibrary!==library)return;collections={albums:[],years:[],months:[]};if(view==='collections'||view==='albums'||period!=='all')showStatus('選集載入失敗','請檢查連線後重試。',fetchCollections)}}
        async function loadMemories(){
            const token=generation;
            showStatus('正在尋找 Memories','請稍候…');
            try{
                const data=await json('/api/memories');
                if(token!==generation||view!=='memories')return;
                memories=Array.isArray(data.memories)?data.memories:[];
                selectedMemory=null;
                renderMemories()
            }catch(_){if(token===generation&&view==='memories')showStatus('Memories 載入失敗','請檢查連線後重試。',loadMemories)}
        }
        function memoryCover(item,host){if(item)coverImage(item,host)}
        function renderMemories(){
            if(view!=='memories')return;
            const host=$('memories-content');host.replaceChildren();clearStatus();host.hidden=false;renderHeader();
            if(!selectedMemory){
                if(!memories.length){showStatus('目前沒有 Memories','已分享圖庫需要足夠的有日期相片。');return}
                const grid=document.createElement('div');grid.className='memory-cards';
                for(const memory of memories){
                    const button=document.createElement('button');button.type='button';button.className='memory-card';
                    const cover=document.createElement('span');cover.className='memory-card-cover';memoryCover(memory.cover,cover);
                    const title=document.createElement('span');title.className='memory-card-title';title.textContent=memory.title;
                    const subtitle=document.createElement('span');subtitle.className='memory-card-subtitle';subtitle.textContent=`${memory.dateRange} · ${memory.items.length} items`;
                    button.append(cover,title,subtitle);button.onclick=()=>{selectedMemory=memory;content.scrollTop=0;renderMemories()};grid.append(button)
                }
                host.append(grid);
                const token=generation;
                requestAnimationFrame(()=>{if(token===generation&&view==='memories'&&host.contains(grid))observeThumbnailJobs(grid.querySelectorAll('.memory-card-cover'))});
                return
            }
            const memory=selectedMemory;
            if(!memory.items.length){host.append(infoElement('p','status','沒有可顯示的相片。'));return}
            const grid=document.createElement('div');grid.className='memory-photo-grid';
            memory.items.forEach((item,index)=>{
                const button=document.createElement('button');button.type='button';button.className='tile';button.setAttribute('aria-label',safeTitle(item));
                const placeholder=document.createElement('span');placeholder.className='placeholder';placeholder.textContent='◌';button.append(placeholder);
                if(item.hasPreview){const img=document.createElement('img');img.alt='';img.loading='lazy';button.append(img);jobs.set(button,{img,placeholder,url:imageURL(item,'thumb'),generation:imageGeneration,attempt:0})}
                appendMediaBadge(item,button);button.onclick=()=>openViewer(memory.items,index,button);grid.append(button)
            });
            host.append(grid);
            const token=generation;
            requestAnimationFrame(()=>{if(token===generation&&view==='memories'&&host.contains(grid))observeThumbnailJobs(grid.children)})
        }
        for(const id of ['desktop-memory-back','mobile-memory-back'])$(id).onclick=()=>{selectedMemory=null;content.scrollTop=0;renderMemories()};
        for(const id of ['desktop-memory-play','mobile-memory-play'])$(id).onclick=event=>{if(selectedMemory)startMemorySlideshow(selectedMemory,event.currentTarget)};
        async function chooseLibrary(id){if(!libraries.some(l=>l.id===id)&&id!=='all')return;library=id;view='library';mediaCategory=null;searchCategory=null;searchVideosOnly=false;period='all';filterYear=null;filterMonth=null;album=null;albumTitle='';search='';collections=null;resetList();setVisibility();if(matchMedia('(max-width:700px)').matches)await loadItems();else await Promise.all([fetchCollections(),loadItems()])}
        function queryParams(limit=pageSize){const p=new URLSearchParams({library,offset:String(offset),limit:String(limit),order:'newest'});if(album)p.set('album',album);if(view==='search'&&search)p.set('q',search);if(view==='videos'||view==='search'&&searchVideosOnly)p.set('type','videos');else if(view==='media'&&mediaCategory)p.set('type',mediaCategory);else if(view==='search'&&searchCategory)p.set('type',searchCategory);if(filterYear)p.set('year',String(filterYear));if(filterMonth)p.set('month',String(filterMonth));return p}
        function createTile(item){const b=document.createElement('button');b.type='button';b.className='tile';b.setAttribute('aria-label',(item.mediaType==='video'?'影片：':item.isLivePhoto?'Live Photo：':'')+safeTitle(item));const placeholder=document.createElement('span');placeholder.className='placeholder';placeholder.textContent='◌';b.append(placeholder);if(item.hasPreview){const img=document.createElement('img');img.alt='';img.decoding='async';img.loading='lazy';b.append(img);jobs.set(b,{img,placeholder,url:imageURL(item,gallery.classList.contains('panorama-list')?'viewer':'thumb'),generation:imageGeneration,attempt:0})}appendMediaBadge(item,b);const label=document.createElement('span');label.className='tile-label';label.textContent=safeTitle(item);b.append(label);b.onclick=()=>openViewer(items,items.indexOf(item),b);return b}
        function loadItems(){
            if(loadPromise)return loadPromise;
            if(view!=='library'&&view!=='videos'&&view!=='media'&&view!=='search'||view==='library'&&period!=='all'||view==='search'&&!search)return Promise.resolve(0);
            const first=items.length===0,token=generation,controller=new AbortController();
            loading=true;request=controller;$('load-more').disabled=true;
            if(first)showStatus(view==='videos'?'正在載入影片':view==='media'?`正在載入 ${mediaTitle(mediaCategory)}`:'正在載入相片','請稍候…');
            loadPromise=(async()=>{
                try{
                    const data=await json('/api/items?'+queryParams(),controller.signal);
                    if(token!==generation)return 0;
                    const batch=Array.isArray(data.items)?data.items.reverse():[];
                    total=Number(data.total)||0;clearStatus();
                    if(first&&!batch.length){showStatus(view==='search'?(searchVideosOnly?'找不到影片':'找不到相片'):view==='videos'?'沒有可瀏覽的影片':view==='media'?`沒有可瀏覽的 ${mediaTitle(mediaCategory)}`:'沒有可瀏覽的相片',view==='search'?'試試其他搜尋字詞。':view==='videos'?'已分享圖庫目前沒有影片。':view==='media'?'已分享圖庫目前沒有此類媒體。':'這個圖庫或相簿目前沒有相片。');renderHeader();return 0}
                    const anchor=gallery.firstElementChild,anchorTop=anchor?.getBoundingClientRect().top;
                    const fragment=document.createDocumentFragment(),buttons=batch.map(createTile);buttons.forEach(button=>fragment.append(button));
                    gallery.prepend(fragment);items.unshift(...batch);offset+=batch.length;
                    if(!first&&viewerItems===items&&viewer.classList.contains('open'))selected+=batch.length;
                    $('load-row').hidden=offset>=total||!batch.length;$('load-more').textContent=view==='videos'?'載入較早影片':'載入較早相片';renderHeader();
                    if(first){initialScrollPending=true;requestAnimationFrame(()=>{if(token===generation){content.scrollTop=content.scrollHeight;observeThumbnailJobs(buttons);initialScrollPending=false}})}
                    else{if(anchor)content.scrollTop+=anchor.getBoundingClientRect().top-anchorTop;observeThumbnailJobs(buttons)}
                    requestAnimationFrame(()=>{if(token===generation&&content.scrollHeight<=content.clientHeight)maybeLoadOlder()});
                    return batch.length
                }catch(error){
                    if(token!==generation)return 0;
                    if(first){if(error.message==='409')showStatus('相簿尚未完成索引','請在 Mac 的 Photo Libraries app 完成圖庫索引後重試。',loadItems);else showStatus(view==='videos'?'影片載入失敗':'相片載入失敗','請檢查連線後重試。',loadItems)}
                    else{$('load-row').hidden=false;$('load-more').textContent='重試載入'}
                    return 0
                }finally{
                    if(token===generation){loading=false;request=null;loadPromise=null;$('load-more').disabled=false}
                }
            })();
            return loadPromise
        }
        function coverImage(cover,host){if(!cover)return;appendMediaBadge(cover,host);if(!cover.hasPreview)return;const img=document.createElement('img');img.alt='';img.loading='lazy';const placeholder=document.createElement('span');placeholder.className='placeholder';host.append(placeholder,img);jobs.set(host,{img,placeholder,url:imageURL(cover,'thumb'),generation:imageGeneration,attempt:0})}
        function addCards(title,entries,label,open){if(!entries?.length)return;const section=document.createElement('section');section.className='collection-section';const h=document.createElement('h2');h.textContent=title;const grid=document.createElement('div');grid.className='cards'+(title==='年份'||title==='月份'?' period-cards':'');for(const entry of entries){const b=document.createElement('button');b.className='card';b.type='button';const cover=document.createElement('span');cover.className='card-cover';coverImage(entry.cover,cover);const name=document.createElement('span');name.className='card-title';name.textContent=label(entry);const count=document.createElement('span');count.className='card-count';count.textContent=`${Number(entry.count||0).toLocaleString()} 張`;b.append(cover,name,count);b.onclick=()=>open(entry);grid.append(b)}section.append(h,grid);$('collections-content').append(section)}
        function albumLabel(album){return album.parent?`${album.parent} / ${album.title}`:album.title}
        const albumCollator=new Intl.Collator('zh-Hant',{numeric:true,sensitivity:'base'});
        function sortedAlbums(albums){return [...albums].sort((a,b)=>albumCollator.compare(a.title,b.title)||albumCollator.compare(a.parent||'',b.parent||'')||albumCollator.compare(a.library||'',b.library||'')||albumCollator.compare(a.id,b.id))}
        function renderCollections(){
            const host=$('collections-content');host.replaceChildren();clearStatus();host.hidden=false;
            if(!collections){showStatus('正在載入選集','請稍候…');return}
            const years=collections.years||[],months=collections.months||[],albums=sortedAlbums(collections.albums||[]);
            const mobileAlbums=view==='albums'&&matchMedia('(max-width:700px)').matches;
            if(view==='collections'){
                addCards('年份',years,x=>String(x.year),x=>openPeriod(x.year,null));
                addCards('月份',months,x=>`${x.year} 年 ${x.month} 月`,x=>openPeriod(x.year,x.month));
                addCards('相簿',albums,x=>x.parent?`${x.parent} / ${x.title}`:x.title,openAlbum);
                const section=document.createElement('section');section.className='collection-section';
                const heading=document.createElement('h2');heading.textContent='位置';
                const mapButton=document.createElement('button');mapButton.type='button';mapButton.className='card';
                mapButton.style.cssText='width:min(100%,220px);padding:20px;text-align:center';mapButton.textContent='◎  地圖';
                mapButton.onclick=()=>openView('map');section.append(heading,mapButton);host.append(section)
            }else if(view==='albums')addCards('相簿',albums,albumLabel,openAlbum);
            else if(period==='years')addCards('年份',years,x=>String(x.year),x=>openPeriod(x.year,null));
            else if(period==='months')addCards('月份',months,x=>`${x.year} 年 ${x.month} 月`,x=>openPeriod(x.year,x.month));
            if(!host.childElementCount){showStatus('沒有選集','目前沒有可瀏覽的日期或相簿。');return}
            const token=generation,shownView=view,shownPeriod=period;
            requestAnimationFrame(()=>{
                if(token!==generation||view!==shownView||period!==shownPeriod||host.hidden)return;
                if(view==='library'&&(period==='years'||period==='months'))content.scrollTop=content.scrollHeight;
                else if(mobileAlbums&&matchMedia('(max-width:700px)').matches)content.scrollTop=content.scrollHeight;
                observeThumbnailJobs(host.querySelectorAll('.card-cover'))
            })
        }
        function selectPeriod(next){if(view!=='library')view='library';album=null;albumTitle='';filterYear=null;filterMonth=null;period=next;resetList();setVisibility();if(next==='all')loadItems();else{if(collections)renderCollections();else fetchCollections()}}
        function openPeriod(year,month){view='library';period='all';album=null;albumTitle='';filterYear=year;filterMonth=month;resetList();setVisibility();loadItems()}
        function openAlbum(a){library=a.library;view='library';period='all';album=a.id;albumTitle=a.title;filterYear=null;filterMonth=null;search='';collections=null;resetList();setVisibility();Promise.all([fetchCollections(),loadItems()])}
        function openMedia(category){if(category==='videos'){openView('videos');return}if(!mediaTypes.some(type=>type.id===category))return;if(library!=='all')collections=null;library='all';view='media';mediaCategory=category;searchCategory=null;searchVideosOnly=false;period='all';album=null;albumTitle='';filterYear=null;filterMonth=null;search='';resetList();setVisibility();loadItems()}
        function openView(next){if(next==='library'){view='library';mediaCategory=null;searchCategory=null;searchVideosOnly=false;search='';period='all';album=null;albumTitle='';filterYear=null;filterMonth=null;resetList();setVisibility();loadItems()}else if(next==='videos'){if(library!=='all')collections=null;library='all';view='videos';mediaCategory=null;searchCategory=null;searchVideosOnly=false;period='all';album=null;albumTitle='';filterYear=null;filterMonth=null;search='';resetList();setVisibility();loadItems()}else if(next==='albums'){view='albums';searchVideosOnly=false;period='all';album=null;albumTitle='';filterYear=null;filterMonth=null;search='';resetList();setVisibility();if(collections)renderCollections();else fetchCollections()}else if(next==='collections'){view='collections';searchVideosOnly=false;period='all';album=null;filterYear=null;filterMonth=null;search='';resetList();setVisibility();if(collections)renderCollections();else fetchCollections()}else if(next==='memories'){library='all';view='memories';selectedMemory=null;period='all';album=null;filterYear=null;filterMonth=null;search='';resetList();setVisibility();loadMemories()}else if(next==='search'){if(view!=='search'){persistView();searchReturnState={view,library,period,album,albumTitle,filterYear,filterMonth,mediaCategory}}searchCategory=view==='media'?mediaCategory:null;searchVideosOnly=view==='videos';view='search';period='all';album=null;filterYear=null;filterMonth=null;resetList();setVisibility();if(search)loadItems();else showStatus(searchVideosOnly?'搜尋影片':'搜尋相片','輸入檔名、日期或其他相片資料。')}else if(next==='map'){mapReturnView=view;mapReturnCategory=mediaCategory;view='map';period='all';album=null;filterYear=null;filterMonth=null;search='';resetList();setVisibility();loadMap()}}
        function closeMobileSearch(){if(view!=='search')return;$('mobile-query').blur();const previous=searchReturnState;searchReturnState=null;search='';searchVideosOnly=false;view=previous?.view||'library';mediaCategory=previous?.mediaCategory||null;searchCategory=null;library=previous?.library||library;period=previous?.period||'all';album=previous?.album||null;albumTitle=previous?.albumTitle||'';filterYear=previous?.filterYear||null;filterMonth=previous?.filterMonth||null;resetList();setVisibility();if(view==='albums'||view==='collections'||period!=='all'){if(collections)renderCollections();else fetchCollections()}else if(view==='memories')loadMemories();else loadItems()}
        function updateMobileSearchOffset(){const viewport=window.visualViewport;if(!viewport)return;const offset=Math.max(0,window.innerHeight-viewport.height-viewport.offsetTop);document.documentElement.style.setProperty('--mobile-search-keyboard-offset',`${offset}px`);document.documentElement.style.setProperty('--mobile-search-safe-inset',offset>80?'0px':'env(safe-area-inset-bottom)')}
        function exitMap(){if(mapReturnView==='media')openMedia(mapReturnCategory);else openView(mapReturnView)}
        let searchTimer=null;function setSearch(value){if(view!=='search'){persistView();searchReturnState={view,library,period,album,albumTitle,filterYear,filterMonth,mediaCategory}}searchCategory=view==='media'?mediaCategory:view==='search'?searchCategory:null;searchVideosOnly=view==='videos'||view==='search'&&searchVideosOnly;search=value.trim();view='search';period='all';album=null;filterYear=null;filterMonth=null;resetList();setVisibility();clearTimeout(searchTimer);if(!search){showStatus(searchVideosOnly?'搜尋影片':'搜尋相片','輸入檔名、日期或其他相片資料。');return}searchTimer=setTimeout(loadItems,230)}
        function ensureMapKit(token){
            if(window.mapkit?.Map&&window.mapkit?.Annotation)return Promise.resolve(window.mapkit);
            if(mapKitPromise)return mapKitPromise;
            mapKitPromise=new Promise((resolve,reject)=>{
                const script=document.createElement('script');let settled=false;
                const finish=error=>{if(settled)return;settled=true;clearTimeout(timer);delete window.webGalleryMapKitReady;if(error){script.remove();reject(error)}else resolve(window.mapkit)};
                const timer=setTimeout(()=>finish(new Error('MapKit timeout')),20000);
                window.webGalleryMapKitReady=()=>{if(window.mapkit?.Map&&window.mapkit?.Annotation)finish(null);else finish(new Error('MapKit unavailable'))};
                script.src='https://cdn.apple-mapkit.com/mk/6/mapkit.core.js';
                script.crossOrigin='anonymous';script.async=true;
                script.dataset.callback='webGalleryMapKitReady';
                script.dataset.libraries='map,annotations';
                script.dataset.token=token;
                script.onerror=()=>finish(new Error('MapKit script failed'));
                document.head.append(script)
            }).catch(error=>{mapKitPromise=null;throw error});
            return mapKitPromise
        }
        function mapPhotoOrder(a,b){
            const left=Date.parse(a.date||'')||0,right=Date.parse(b.date||'')||0;
            return right-left||`${a.library}:${a.id}`.localeCompare(`${b.library}:${b.id}`)
        }
        function mapGroups(points){
            const regions=new Map();
            points.forEach((item,index)=>{
                const location=item.location;if(!location)return;
                const key=`${Math.floor((location.latitude+90)/0.05)}:${Math.floor((location.longitude+180)/0.05)}`;
                if(!regions.has(key))regions.set(key,[]);
                regions.get(key).push(index)
            });
            return [...regions].map(([id,indices])=>{
                indices.sort((a,b)=>mapPhotoOrder(points[a],points[b]));
                const center={latitude:0,longitude:0},coordinates=new Map();
                for(const index of indices){
                    const point=points[index].location;
                    center.latitude+=point.latitude;center.longitude+=point.longitude;
                    const key=`${point.latitude},${point.longitude}`;
                    if(!coordinates.has(key))coordinates.set(key,{location:point,count:0});
                    coordinates.get(key).count++
                }
                center.latitude/=indices.length;center.longitude/=indices.length;
                const longitudeScale=Math.cos(center.latitude*Math.PI/180);
                const distance=point=>(point.latitude-center.latitude)**2+((point.longitude-center.longitude)*longitudeScale)**2;
                const location=[...coordinates.values()].sort((a,b)=>b.count-a.count||distance(a.location)-distance(b.location)||a.location.latitude-b.location.latitude||a.location.longitude-b.location.longitude)[0].location;
                return {id,indices,location}
            }).sort((a,b)=>a.id.localeCompare(b.id))
        }
        function photoAnnotation(mk,location,indices,clusterable){
            const photo=mapItems[indices[0]];
            const annotation=new mk.Annotation(location,()=>{
                const marker=document.createElement('div');marker.className='photo-map-marker';
                const count=document.createElement('span');count.className='photo-map-count';count.textContent=indices.length.toLocaleString();
                const imageHost=document.createElement('span');imageHost.className='photo-map-image';
                const placeholder=document.createElement('span');placeholder.className='placeholder';placeholder.textContent='▧';imageHost.append(placeholder);
                if(photo.hasPreview){
                    const img=document.createElement('img');img.alt='';img.decoding='async';imageHost.append(img);
                    jobs.set(imageHost,{img,placeholder,url:imageURL(photo,'thumb'),generation:imageGeneration,attempt:0});imageObserver.observe(imageHost)
                }
                appendMediaBadge(photo,imageHost);marker.append(count,imageHost);return marker
            },{
                title:safeTitle(photo),data:{indices},size:{width:68,height:78},
                calloutEnabled:false,clusteringIdentifier:clusterable?'gallery-photos':null
            });
            annotation.accessibilityLabel=`${indices.length.toLocaleString()} 張相片`;return annotation
        }
        function showMapPhotos(indices){
            const photos=[...new Set(indices)].map(index=>mapItems[index]).filter(Boolean).sort(mapPhotoOrder);
            if(!photos.length)return;
            const pane=$('map-photo-pane'),grid=$('map-photo-grid');grid.replaceChildren();
            $('map-photo-count').textContent=`${photos.length.toLocaleString()} 張相片`;
            photos.forEach((item,index)=>{
                const button=document.createElement('button');button.type='button';button.className='map-photo-tile';button.setAttribute('aria-label',safeTitle(item));
                const placeholder=document.createElement('span');placeholder.className='placeholder';placeholder.textContent='◌';button.append(placeholder);
                if(item.hasPreview){
                    const img=document.createElement('img');img.alt='';img.loading='lazy';img.decoding='async';button.append(img);
                    jobs.set(button,{img,placeholder,url:imageURL(item,'thumb'),generation:imageGeneration,attempt:0})
                }
                appendMediaBadge(item,button);button.onclick=()=>openViewer(photos,index,button);grid.append(button)
            });
            $('map-pane').classList.add('map-covered');pane.hidden=false;$('map-exit').hidden=true;$('map-photo-scroll').scrollTop=0;
            const token=generation;
            requestAnimationFrame(()=>{if(token===generation&&!pane.hidden)observeThumbnailJobs(grid.querySelectorAll('.map-photo-tile'))});
            $('desktop-title').textContent='Map Photos';$('mobile-title').textContent='地圖相片';$('map-back').focus()
        }
        function backToMap(){
            $('map-photo-pane').hidden=true;$('map-photo-grid').replaceChildren();$('map-pane').classList.remove('map-covered');$('map-exit').hidden=false;
            $('desktop-title').textContent='地圖';$('mobile-title').textContent='地圖'
        }
        async function loadMap(){
            const host=$('map-content');host.replaceChildren();showStatus('正在載入地圖','請稍候…');
            const token=generation,controller=new AbortController();request=controller;
            try{
                let tokenData;
                try{tokenData=await json('/api/map-token',controller.signal)}catch(error){
                    if(token!==generation||view!=='map')return;
                    if(error.message==='404'){showStatus('需要設定 Apple 地圖','請在 Mac 的 Web Gallery 設定填入 MapKit JS Maps token。');return}
                    throw error
                }
                if(token!==generation||view!=='map')return;
                const [data,mk]=await Promise.all([json('/api/map',controller.signal),ensureMapKit(tokenData.token)]);
                if(view!=='map'||token!==generation)return;
                const points=Array.isArray(data.items)?data.items:[];
                mapItems=points;
                if(!points.length){showStatus('沒有位置資料','已分享相片中沒有可顯示的位置。');return}
                if(!mapKitErrorHandlerBound){
                    mk.addEventListener('error',()=>{if(view==='map'){appleMap?.destroy();appleMap=null;showStatus('Apple 地圖授權失敗','請檢查 Maps token、網域限制及連線。')}});
                    mapKitErrorHandlerBound=true
                }
                clearStatus();host.hidden=false;
                const mapPane=document.createElement('div');mapPane.className='map-pane';mapPane.id='map-pane';
                const mapNode=document.createElement('div');mapNode.className='map-wrap';
                mapNode.setAttribute('aria-label','Apple 地圖：已分享相片的位置');mapPane.append(mapNode);
                const photoPane=document.createElement('section');photoPane.className='map-photo-pane';photoPane.id='map-photo-pane';photoPane.hidden=true;
                const header=document.createElement('div');header.className='map-photo-header';
                const back=document.createElement('button');back.type='button';back.className='map-back';back.id='map-back';back.textContent='‹ 返回地圖';back.onclick=backToMap;
                const heading=document.createElement('div');heading.className='map-photo-heading';heading.textContent='Map Photos';
                const count=document.createElement('div');count.className='map-photo-count';count.id='map-photo-count';
                const summary=document.createElement('div');summary.append(heading,count);header.append(back,summary);
                const scroll=document.createElement('div');scroll.className='map-photo-scroll';scroll.id='map-photo-scroll';
                const grid=document.createElement('div');grid.className='map-photo-grid';grid.id='map-photo-grid';scroll.append(grid);
                photoPane.append(header,scroll);host.append(mapPane,photoPane);
                const groups=mapGroups(points);
                const densest=groups.reduce((best,group)=>!best||group.indices.length>best.indices.length||group.indices.length===best.indices.length&&group.id>best.id?group:best,null);
                appleMap=new mk.Map(mapNode,{
                    colorScheme:mk.ColorScheme.Adaptive,
                    showsMapTypeControl:true,showsZoomControl:true,showsScale:mk.FeatureVisibility.Visible,
                    showsCompass:mk.FeatureVisibility.Visible,
                    region:densest?{center:densest.location,span:{latitudeDelta:0.5,longitudeDelta:0.5}}:undefined
                });
                const annotations=groups.map(group=>photoAnnotation(mk,group.location,group.indices,true));
                appleMap.annotationForCluster=cluster=>{
                    const indices=[...new Set((cluster.memberAnnotations||[]).flatMap(member=>member.data?.indices||[]))];
                    if(!indices.length)return cluster;
                    indices.sort((a,b)=>mapPhotoOrder(points[a],points[b]));
                    return photoAnnotation(mk,cluster.coordinate,indices,false)
                };
                appleMap.addAnnotations(annotations);
                appleMap.addEventListener('select',event=>{
                    const selected=event.annotation;if(!selected)return;
                    const indices=selected.data?.indices||selected.memberAnnotations?.flatMap(member=>member.data?.indices||[])||[];
                    showMapPhotos(indices);
                    selected.selected=false
                });
            }catch(_){
                if(view==='map'&&token===generation){appleMap?.destroy();appleMap=null;showStatus('地圖載入失敗','請檢查 Apple 地圖連線與 Maps token 後重試。',loadMap)}
            }finally{if(request===controller)request=null}
        }
        function infoElement(tag,className,value){const node=document.createElement(tag);if(className)node.className=className;node.textContent=value;return node}
        function metaRow(label,value){const row=infoElement('div','meta-row','');row.append(infoElement('span','',label),infoElement('strong','',value));return row}
        function infoNumber(value,digits=1){return Number(value).toLocaleString(undefined,{maximumFractionDigits:digits})}
        function infoBytes(bytes){if(bytes<1000)return `${bytes} bytes`;const units=['KB','MB','GB','TB'];let value=bytes,index=-1;do{value/=1000;index++}while(value>=1000&&index<units.length-1);return `${infoNumber(value,1)} ${units[index]}`}
        function shutterSpeed(seconds){if(!(seconds>0))return '— s';return seconds<1?`1/${Math.max(Math.round(1/seconds),1)} s`:`${infoNumber(seconds,2)} s`}
        function infoCard(item){
            const card=infoElement('div','info-card',''),metadata=item.technicalMetadata,isVideo=item.mediaType==='video';
            if(!metadata){
                if(item.isLivePhoto){const badge=infoElement('span','info-live','◎');badge.title='Live Photo';badge.setAttribute('aria-label','Live Photo');card.append(badge)}
                for(const detail of item.details||[])card.append(metaRow(detail.label,detail.value));
                if(!item.details?.length)card.append(infoElement('div','info-loading',isVideo?'影片資料無法讀取':'讀取相機資料中…'));
                return card
            }
            const make=metadata.cameraMake,model=metadata.cameraModel;
            const camera=isVideo?'Video':model&&make&&!model.toLowerCase().includes(make.toLowerCase())?`${make} ${model}`:model||make||'Camera information unavailable';
            const cameraLine=infoElement('div','info-card-line','');cameraLine.append(infoElement('span','',camera));
            cameraLine.append(infoElement('span','spacer',''));
            if(!isVideo&&metadata.whiteBalance){const whiteBalance=infoElement('span','','◉');whiteBalance.title=`White Balance: ${metadata.whiteBalance}`;cameraLine.append(whiteBalance)}
            const cameraIcon=infoElement('span','',isVideo?'▣':'⊡');cameraIcon.title=isVideo?'Video metadata':'Camera metadata';cameraLine.append(cameraIcon);
            card.append(cameraLine);
            const focal=metadata.focalLengthIn35mm??metadata.focalLength;
            if(!isVideo)card.append(infoElement('div','info-card-line',focal==null?'Focal length unavailable':`${infoNumber(focal)} mm`));
            const size=infoElement('div','info-card-line','');
            if(!isVideo&&metadata.pixelWidth>0&&metadata.pixelHeight>0)size.append(infoElement('span','',`${infoNumber(metadata.pixelWidth*metadata.pixelHeight/1000000)} MP`));
            if(metadata.pixelWidth!=null&&metadata.pixelHeight!=null)size.append(infoElement('span','',`${metadata.pixelWidth} × ${metadata.pixelHeight}`));
            size.append(infoElement('span','spacer',''));
            if(metadata.fileSize!=null)size.append(infoElement('span','',infoBytes(metadata.fileSize)));
            if(metadata.fileFormat)size.append(infoElement('span','info-format',metadata.fileFormat==='HEIC'?'HEIF':metadata.fileFormat));
            if(item.isLivePhoto){const badge=infoElement('span','info-live','◎');badge.title='Live Photo';badge.setAttribute('aria-label','Live Photo');size.append(badge)}
            card.append(size,infoElement('div','info-card-rule',''));
            if(isVideo){
                if(metadata.videoDuration>0)card.append(metaRow('Duration',videoDuration(metadata.videoDuration)));
                if(metadata.videoFrameRate>0)card.append(metaRow('Frame Rate',`${infoNumber(metadata.videoFrameRate)} fps`));
                if(metadata.videoCodec)card.append(metaRow('Codec',metadata.videoCodec));
            }else{
                const metrics=infoElement('div','info-metrics','');
                for(const [label,value] of [
                    ['ISO',metadata.iso==null?'ISO —':`ISO ${infoNumber(metadata.iso)}`],
                    ['35mm-equivalent focal length',focal==null?'— mm':`${infoNumber(focal)} mm`],
                    ['Exposure compensation',metadata.exposureBias==null?'— ev':`${infoNumber(metadata.exposureBias,2)} ev`],
                    ['Aperture',metadata.aperture==null?'ƒ—':`ƒ${infoNumber(metadata.aperture,2)}`],
                    ['Shutter speed',shutterSpeed(metadata.exposureTime)]
                ]){const metric=infoElement('span','',value);metric.title=label;metrics.append(metric)}
                card.append(metrics);
            }
            const remainingDetails=(item.details||[]).filter(detail=>
                (detail.label!=='Dimensions'||metadata.pixelWidth==null||metadata.pixelHeight==null)
                &&(detail.label!=='File Size'||metadata.fileSize==null)
                &&(detail.label!=='Duration'||metadata.videoDuration==null));
            if(remainingDetails.length){card.append(infoElement('div','info-card-rule',''));for(const detail of remainingDetails)card.append(metaRow(detail.label,detail.value))}
            return card
        }
        let viewerInfoRequest=null,viewerPlaceRequest=null,viewerInfoGeneration=0,viewerLocationMap=null;
        function clearViewerInfo(){viewerInfoGeneration++;viewerInfoRequest?.abort();viewerInfoRequest=null;viewerPlaceRequest?.abort();viewerPlaceRequest=null;viewerLocationMap?.destroy();viewerLocationMap=null}
        async function infoLocationAddress(host,item,token){
            const controller=new AbortController();viewerPlaceRequest=controller;
            try{
                const data=await json('/api/place?'+new URLSearchParams({library:item.library,id:item.id}),controller.signal);
                if(token===viewerInfoGeneration&&host.isConnected)host.textContent=data.address||'Address unavailable'
            }catch(error){
                if(error.name!=='AbortError'&&token===viewerInfoGeneration&&host.isConnected)host.textContent='Address unavailable'
            }finally{if(viewerPlaceRequest===controller)viewerPlaceRequest=null}
        }
        async function infoLocationMap(host,location,token){
            try{
                const data=await json('/api/map-token');
                const mk=await ensureMapKit(data.token);
                if(token!==viewerInfoGeneration||!host.isConnected)return;
                viewerLocationMap?.destroy();
                viewerLocationMap=new mk.Map(host,{colorScheme:mk.ColorScheme.Adaptive,showsZoomControl:true,region:{center:location,span:{latitudeDelta:0.015,longitudeDelta:0.015}}});
                viewerLocationMap.addAnnotations([new mk.Annotation(location,()=>infoElement('div','info-map-marker','●'),{title:'Photo Location'})])
            }catch(_){host.remove()}
        }
        function renderViewerInfo(item,token){
            if(token!==viewerInfoGeneration)return;
            const info=$('viewer-info');info.replaceChildren();
            info.append(infoElement('div','info-heading','Info'));
            const titleRow=infoElement('div','info-title-row','');
            titleRow.append(infoElement('div','info-title'+(item.title?'':' info-placeholder'),item.title||'Title'));
            titleRow.append(infoElement('span','info-heart'+(item.isFavorite?' favorite':''),item.isFavorite?'♥':'♡'));
            info.append(titleRow,infoElement('div','info-filename',item.filename||'—'),infoElement('div','info-date'+(item.dateText?'':' empty'),item.dateText||'—'));
            info.append(infoCard(item));
            for(const [value,placeholder] of [[item.caption,'Caption'],[Array.isArray(item.keywords)?item.keywords.join(', '):'','Keyword']]){
                info.append(infoElement('div','info-section'+(value?'':' info-placeholder'),value||placeholder))
            }
            if(item.location){
                const section=infoElement('div','info-section','');
                const address=infoElement('div','','Resolving location…');section.append(address);
                const map=infoElement('div','info-map','');section.append(map);
                const coordinates=infoElement('div','info-coordinates','');
                coordinates.append(infoElement('span','info-coordinate-label','Coordinates'),infoElement('span','',`${item.location.latitude}, ${item.location.longitude}`));
                section.append(coordinates);
                info.append(section);infoLocationAddress(address,item,token);infoLocationMap(map,item.location,token)
            }
        }
        function resetLivePlayback(){viewerLiveVideo.pause();viewerLiveVideo.removeAttribute('src');viewerLiveVideo.load();viewerLiveVideo.hidden=true;viewerLivePlay.disabled=false;$('viewer-video-note').hidden=true}
        function stopMemorySlideshow(){
            clearTimeout(memoryTimer);memoryTimer=null;clearTimeout(memoryPauseHideTimer);memoryPauseHideTimer=null;memorySlideshow=false;memoryPaused=false;
            memoryMusic.pause();memoryMusic.removeAttribute('src');memoryMusic.load();memoryMusicFailed=false;
            $('memory-controls').hidden=true
        }
        function showMemoryPauseControl(){
            if(!memorySlideshow)return;
            clearTimeout(memoryPauseHideTimer);$('memory-pause').hidden=false;
            if(!memoryPaused)memoryPauseHideTimer=setTimeout(()=>{
                memoryPauseHideTimer=null;
                if(!memorySlideshow||memoryPaused)return;
                if($('memory-pause').matches(':hover')||document.activeElement===$('memory-pause'))showMemoryPauseControl();
                else $('memory-pause').hidden=true
            },2000)
        }
        function startMemorySlideshow(memory,focus){
            if(!memory.items.length)return;
            stopMemorySlideshow();memorySlideshow=true;memoryRemaining=2000;
            const tracks=['memory-warmth','memory-dream','memory-journey','memory-stillness'];
            const choices=tracks.filter(track=>track!==previousTrack),track=choices[Math.floor(Math.random()*choices.length)]||tracks[0];previousTrack=track;
            memoryMusic.src='/api/memory-music?'+new URLSearchParams({track});
            openViewer(memory.items,0,focus);
            if(viewer.requestFullscreen){
                viewer.requestFullscreen().then(()=>{
                    if(!memorySlideshow&&document.fullscreenElement===viewer)document.exitFullscreen().catch(()=>{})
                }).catch(()=>{})
            }
        }
        function scheduleMemorySlide(){
            clearTimeout(memoryTimer);memoryTimer=null;
            if(!memorySlideshow)return;
            $('memory-controls').hidden=false;
            if(memoryPaused){clearTimeout(memoryPauseHideTimer);memoryPauseHideTimer=null;$('memory-pause').hidden=false}
            else if(!memoryPauseHideTimer)$('memory-pause').hidden=true;
            $('memory-pause').textContent=memoryPaused?'繼續':'暫停';
            $('memory-pause').setAttribute('aria-label',memoryPaused?'繼續回憶播放':'暫停回憶播放');
            $('memory-progress').textContent=`${selected+1} / ${viewerItems.length}${memoryMusicFailed?' · 配樂暫不可用':''}`;
            if(memoryPaused)return;
            const item=viewerItems[selected];
            if(item?.mediaType==='video'&&item.canPlay){
                memoryMusic.pause();
                viewerVideo.play().catch(()=>{if(memorySlideshow&&!memoryPaused){memoryStarted=performance.now();memoryTimer=setTimeout(()=>moveViewer(1),2000)}});
                return
            }
            memoryMusic.play().catch(error=>{if(memorySlideshow&&error.name!=='AbortError'){memoryMusicFailed=true;$('memory-progress').textContent=`${selected+1} / ${viewerItems.length} · 配樂暫不可用`}});
            memoryStarted=performance.now();
            memoryTimer=setTimeout(()=>moveViewer(1),memoryRemaining)
        }
        function toggleMemoryPause(){
            if(!memorySlideshow)return;
            const item=viewerItems[selected];
            if(!memoryPaused){
                if(memoryTimer)memoryRemaining=Math.max(0,memoryRemaining-(performance.now()-memoryStarted));
                clearTimeout(memoryTimer);memoryTimer=null;clearTimeout(memoryPauseHideTimer);memoryPauseHideTimer=null;viewerVideo.pause();memoryMusic.pause();memoryPaused=true
            }else{memoryPaused=false;if(item?.mediaType==='video'&&item.canPlay)viewerVideo.play().catch(()=>{if(memorySlideshow&&!memoryPaused){memoryStarted=performance.now();memoryTimer=setTimeout(()=>moveViewer(1),memoryRemaining)}});else scheduleMemorySlide()}
            $('memory-pause').textContent=memoryPaused?'繼續':'暫停';
            $('memory-pause').setAttribute('aria-label',memoryPaused?'繼續回憶播放':'暫停回憶播放');
            $('memory-pause').hidden=!memoryPaused
        }
        function playLivePhoto(){
            const item=viewerItems[selected];if(!item?.isLivePhoto||viewerLivePlay.disabled)return;
            viewerLivePlay.disabled=true;
            const note=$('viewer-video-note');note.textContent='正在載入 Live Photo…';note.hidden=false;
            viewerLiveVideo.src=videoURL(item,true);
            viewerLiveVideo.play().catch(error=>{
                if(viewerItems[selected]!==item||!viewer.classList.contains('open'))return;
                viewerLiveVideo.hidden=true;viewerLivePlay.disabled=false;
                note.textContent=error.name==='NotAllowedError'?'請點按 ◎ Live 以有聲播放。':'Live Photo 暫時無法播放，請確認動態片段已儲存在這部 Mac 上。';note.hidden=false
            })
        }
        function renderViewer(){
            const item=viewerItems[selected];if(!item)return;
            clearViewerInfo();const token=viewerInfoGeneration;
            viewerVideo.pause();viewerVideo.removeAttribute('src');viewerVideo.removeAttribute('poster');viewerVideo.load();
            resetLivePlayback();viewerLivePlay.hidden=!item.isLivePhoto;
            const playable=item.mediaType==='video'&&item.canPlay;
            const videoNote=$('viewer-video-note');videoNote.textContent='影片暫時無法播放，請確認圖庫已連接且原檔儲存在這部 Mac 上。';
            viewerVideo.hidden=!playable;$('viewer-photo').hidden=playable;videoNote.hidden=item.mediaType!=='video'||playable;
            if(playable){
                viewerImage.removeAttribute('src');viewerVideo.poster=imageURL(item,'viewer');viewerVideo.src=videoURL(item);
                const source=viewerVideo.src;
                setTimeout(()=>{
                    if(viewer.classList.contains('open')&&viewerItems[selected]===item&&viewerVideo.src===source&&viewerVideo.readyState<2&&videoNote.hidden){
                        videoNote.textContent='影片仍在準備中。大型原檔可能需要較長時間；請保持此頁面開啟。';videoNote.hidden=false
                    }
                },60000)
            }
            else{viewerImage.alt=safeTitle(item);viewerImage.src=imageURL(item,'viewer')}
            $('viewer-photo').disabled=item.mediaType==='video';$('viewer-title').textContent=safeTitle(item);
            const caption=$('viewer-caption');caption.replaceChildren();
            const title=infoElement('span','',safeTitle(item)),date=infoElement('small','',dateLabel(item));caption.append(title,date);
            $('viewer-prev').disabled=selected<=0&&(viewerItems!==items||offset>=total);
            $('viewer-next').disabled=selected>=viewerItems.length-1;
            const loading={...item,title:'',dateText:dateLabel(item),details:[],location:null};
            renderViewerInfo(loading,token);
            const controller=new AbortController();viewerInfoRequest=controller;
            json('/api/item?'+new URLSearchParams({library:item.library,id:item.id}),controller.signal)
                .then(data=>{if(token===viewerInfoGeneration&&viewer.classList.contains('open')&&data.item)renderViewerInfo(data.item,token)})
                .catch(error=>{if(error.name!=='AbortError'&&token===viewerInfoGeneration)$('viewer-info').append(infoElement('div','info-loading','相片資訊暫不可用'))});
            if(memorySlideshow&&viewer.classList.contains('open')){memoryRemaining=2000;scheduleMemorySlide()}
        }
        function setViewerExpanded(expanded){const item=viewerItems[selected],video=item?.mediaType==='video';if(video||memorySlideshow)expanded=false;if(expanded)resetLivePlayback();viewerLivePlay.hidden=expanded||!item?.isLivePhoto;viewer.classList.toggle('expanded',expanded);viewer.setAttribute('aria-label',memorySlideshow?'Memories 播放，空白鍵暫停或繼續':video?'影片預覽':expanded?'相片放大檢視':'相片預覽');$('viewer-photo').disabled=expanded||video||memorySlideshow;$('viewer-close').textContent=expanded?'‹ 返回預覽':'‹ 返回相片';$('viewer-close').focus()}
        function openViewer(source,index,focus){viewerItems=source;selected=index;previousFocus=focus;renderViewer();viewer.classList.add('open');viewer.setAttribute('aria-hidden','false');document.body.style.overflow='hidden';setViewerExpanded(false);if(memorySlideshow)scheduleMemorySlide()}
        function closeViewer(){if(document.fullscreenElement===viewer)document.exitFullscreen().catch(()=>{});stopMemorySlideshow();clearViewerInfo();resetLivePlayback();viewerVideo.pause();viewerVideo.removeAttribute('src');viewerVideo.removeAttribute('poster');viewerVideo.load();viewer.classList.remove('open','expanded');viewer.setAttribute('aria-hidden','true');viewerImage.removeAttribute('src');$('viewer-info').classList.remove('open-mobile');document.body.style.overflow='';previousFocus?.focus()}
        document.addEventListener('fullscreenchange',()=>{if(document.fullscreenElement===viewer){memoryFullscreenActive=true;return}const wasMemoryFullscreen=memoryFullscreenActive;memoryFullscreenActive=false;if(wasMemoryFullscreen&&memorySlideshow)closeViewer()});
        viewer.addEventListener('pointermove',e=>{if(e.pointerType==='mouse')showMemoryPauseControl()});
        viewer.addEventListener('pointerdown',showMemoryPauseControl);
        function moveViewer(direction){const next=selected+direction;if(next>=0&&next<viewerItems.length){selected=next;renderViewer()}else if(memorySlideshow&&next>=viewerItems.length){closeViewer()}else if(direction<0&&viewerItems===items&&offset<total){loadItems().then(loaded=>{if(loaded&&viewer.classList.contains('open')&&viewerItems===items&&selected>0){selected--;renderViewer()}})}}
        let touchX=null;$('viewer-main').addEventListener('touchstart',e=>{touchX=viewerVideo.hidden?e.changedTouches[0]?.screenX??null:null},{passive:true});$('viewer-main').addEventListener('touchend',e=>{if(touchX===null)return;const delta=(e.changedTouches[0]?.screenX??touchX)-touchX;if(Math.abs(delta)>45)moveViewer(delta<0?1:-1);touchX=null},{passive:true});
        viewerVideo.onerror=async()=>{
            if(viewerVideo.hidden||!viewer.classList.contains('open'))return;
            const item=viewerItems[selected],note=$('viewer-video-note'),source=viewerVideo.currentSrc;
            note.textContent='正在檢查影片播放問題…';note.hidden=false;
            try{
                const response=await fetch(videoURL(item),{headers:{Range:'bytes=0-0'}});
                if(viewerItems[selected]!==item||viewerVideo.currentSrc!==source||!viewer.classList.contains('open'))return;
                note.textContent=response.status===404?'無法讀取這部 Mac 上的影片原檔。':response.status===500?'影片轉換為網頁格式時失敗。':response.ok?'瀏覽器無法解碼這段影片。':'影片暫時無法播放（HTTP '+response.status+'）。'
            }catch(_){if(viewerItems[selected]===item&&viewer.classList.contains('open'))note.textContent='影片連線失敗，請稍後重試。'}
        };
        viewerVideo.onplaying=()=>{$('viewer-video-note').hidden=true};
        viewerVideo.onended=()=>{if(memorySlideshow&&!memoryPaused)moveViewer(1)};
        $('memory-pause').onclick=toggleMemoryPause;
        viewerLiveVideo.onplaying=()=>{if(viewer.classList.contains('open')){viewerLiveVideo.hidden=false;$('viewer-video-note').hidden=true}};
        viewerLiveVideo.onended=resetLivePlayback;
        viewerLiveVideo.onerror=()=>{if(viewerLiveVideo.hasAttribute('src')&&viewer.classList.contains('open')){viewerLiveVideo.hidden=true;viewerLivePlay.disabled=false;const note=$('viewer-video-note');note.textContent='Live Photo 暫時無法播放，請確認動態片段已儲存在這部 Mac 上。';note.hidden=false}};
        let liveBadgeHovered=false;
        viewerLivePlay.onpointerenter=e=>{if(e.pointerType==='mouse'&&!liveBadgeHovered){liveBadgeHovered=true;playLivePhoto()}};
        viewerLivePlay.onpointerleave=()=>{liveBadgeHovered=false};
        viewerLivePlay.onclick=playLivePhoto;
        $('viewer-photo').onclick=()=>setViewerExpanded(true);$('viewer-close').onclick=()=>viewer.classList.contains('expanded')?setViewerExpanded(false):closeViewer();$('viewer-prev').onclick=()=>moveViewer(-1);$('viewer-next').onclick=()=>moveViewer(1);$('viewer-info-toggle').onclick=()=>{if(matchMedia('(max-width:700px)').matches){$('viewer-info').classList.remove('closed');$('viewer-info').classList.toggle('open-mobile')}else $('viewer-info').classList.toggle('closed')};document.addEventListener('keydown',e=>{if(!viewer.classList.contains('open'))return;if(e.key==='Escape'){if(viewer.classList.contains('expanded'))setViewerExpanded(false);else closeViewer()}if(memorySlideshow&&e.code==='Space'){e.preventDefault();if(!e.repeat)toggleMemoryPause()}if(e.target===viewerVideo)return;if(['ArrowLeft','ArrowUp','ArrowRight','ArrowDown'].includes(e.key)){e.preventDefault();moveViewer(e.key==='ArrowLeft'||e.key==='ArrowUp'?-1:1)}});
        $('sidebar-toggle').onclick=()=>{const sidebar=$('desktop-sidebar'),expanded=sidebar.hidden;sidebar.hidden=!expanded;$('sidebar-toggle').setAttribute('aria-expanded',String(expanded));$('sidebar-toggle').setAttribute('aria-label',expanded?'隱藏側邊欄':'顯示側邊欄');persistView()};
        function closeMobileMenus(){for(const [button,menu] of [['mobile-library-button','mobile-library-menu'],['mobile-filter-button','mobile-filter-menu']]){$(menu).hidden=true;$(button).setAttribute('aria-expanded','false')}}
        function toggleMobileMenu(buttonID,menuID){const willOpen=$(menuID).hidden;closeMobileMenus();$(menuID).hidden=!willOpen;$(buttonID).setAttribute('aria-expanded',String(willOpen))}
        $('mobile-library-button').onclick=()=>toggleMobileMenu('mobile-library-button','mobile-library-menu');
        $('mobile-filter-button').onclick=()=>toggleMobileMenu('mobile-filter-button','mobile-filter-menu');
        $('mobile-search-button').onclick=()=>{closeMobileMenus();openView('search');requestAnimationFrame(()=>$('mobile-query').focus())};
        $('mobile-search-close').onclick=closeMobileSearch;
        window.visualViewport?.addEventListener('resize',updateMobileSearchOffset);
        window.visualViewport?.addEventListener('scroll',updateMobileSearchOffset);
        window.addEventListener('resize',updateMobileSearchOffset);
        updateMobileSearchOffset();
        document.querySelectorAll('[data-mobile-destination]').forEach(b=>b.onclick=()=>{closeMobileMenus();openView(b.dataset.mobileDestination)});
        document.querySelectorAll('[data-mobile-filter]').forEach(b=>b.onclick=()=>{closeMobileMenus();openView(b.dataset.mobileFilter)});
        document.addEventListener('click',e=>{if(!e.target.closest('.mobile-library-wrap,.mobile-filter-wrap'))closeMobileMenus()});
        document.addEventListener('keydown',e=>{if(e.key==='Escape')closeMobileMenus()});
        $('nav-all').onclick=()=>chooseLibrary('all');$('nav-memories').onclick=()=>openView('memories');$('nav-map').onclick=()=>openView('map');$('nav-videos').onclick=()=>openView('videos');$('map-exit').onclick=exitMap;$('load-more').onclick=loadItems;$('zoom-out').onclick=()=>{zoom=Math.max(90,zoom-20);gallery.style.setProperty('--tile-size',`${zoom}px`);persistView()};$('zoom-in').onclick=()=>{zoom=Math.min(260,zoom+20);gallery.style.setProperty('--tile-size',`${zoom}px`);persistView()};$('back-period').onclick=()=>{if(album){album=null;albumTitle='';resetList();setVisibility();loadItems()}else if(filterYear){const next=filterMonth?'months':'years';selectPeriod(next)}};document.querySelectorAll('[data-period]').forEach(b=>b.onclick=()=>selectPeriod(b.dataset.period));document.querySelectorAll('[data-tab]').forEach(b=>b.onclick=()=>openView(b.dataset.tab));$('desktop-query').oninput=e=>setSearch(e.target.value);$('mobile-query').oninput=e=>setSearch(e.target.value);
        async function restoreSavedView(saved){
            restoringScroll=true;
            if(Number.isFinite(saved?.zoom))zoom=Math.max(90,Math.min(260,saved.zoom));
            gallery.style.setProperty('--tile-size',`${zoom}px`);
            if(saved?.sidebarExpanded===false){$('desktop-sidebar').hidden=true;$('sidebar-toggle').setAttribute('aria-expanded','false');$('sidebar-toggle').setAttribute('aria-label','顯示側邊欄')}
            const validLibrary=saved?.library==='all'||libraries.some(l=>l.id===saved?.library);let validDestination=validLibrary;
            library=validLibrary?saved.library:'all';
            view=validLibrary&&['library','albums','collections','map','videos','media','memories'].includes(saved?.view)?saved.view:'library';
            period=view==='library'&&validLibrary&&['all','years','months'].includes(saved?.period)?saved.period:'all';
            mediaCategory=view==='media'&&mediaTypes.some(type=>type.id===saved?.mediaCategory&&type.id!=='videos')?saved.mediaCategory:null;
            if(view==='media'&&!mediaCategory){view='library';validDestination=false}
            if(view==='media'||view==='videos'||view==='memories')library='all';
            let collectionsFailed=false;
            const mobile=matchMedia('(max-width:700px)').matches;
            const needsCollections=view==='albums'||view==='collections'||view==='library'&&(period!=='all'||!!saved?.album||!!saved?.filterYear);
            if(needsCollections)try{collections=await json('/api/collections?'+new URLSearchParams({library}))}catch(_){collections=null;collectionsFailed=true}
            if(collectionsFailed&&(saved?.album||period!=='all'||view==='albums'||view==='collections')){setVisibility();showStatus('選集載入失敗','請檢查連線後重試。',start);restoringScroll=false;return}
            if(saved?.album&&view==='library'){
                const found=collections?.albums?.find(a=>a.id===saved.album&&a.library===library);
                if(found){album=found.id;albumTitle=found.title;period='all'}
                else{library='all';view='library';period='all';collections=null;validDestination=false}
            }else if(view==='library'&&saved?.filterYear){
                const year=Number(saved.filterYear),month=saved.filterMonth==null?null:Number(saved.filterMonth);
                const exists=Number.isInteger(year)&&(month===null?collections?.years?.some(y=>Number(y.year)===year):Number.isInteger(month)&&collections?.months?.some(m=>Number(m.year)===year&&Number(m.month)===month));
                if(exists){filterYear=year;filterMonth=month;period='all'}else validDestination=false
            }
            setVisibility();
            if(view==='library'&&period==='all'||view==='videos'||view==='media')await loadItems();
            else if(view==='map')await loadMap();
            else if(view==='memories')await loadMemories();
            else if(collections)renderCollections();
            else await fetchCollections();
            if(!collections&&view==='library'&&period==='all'&&!mobile)fetchCollections();
            await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
            const distance=Number(saved?.scrollFromBottom);
            if(view==='memories')content.scrollTop=0;
            else if(view!=='map'&&validDestination&&Number.isFinite(distance)&&distance>0){
                const target=Math.max(0,distance);
                while((view==='library'&&period==='all'||view==='videos'||view==='media')&&content.scrollHeight-content.clientHeight<target&&offset<total){if(!await loadItems())break}
                content.scrollTop=Math.max(0,content.scrollHeight-content.clientHeight-target)
            }
            restoringScroll=false;persistenceReady=true;persistView();if(content.scrollHeight<=content.clientHeight)maybeLoadOlder()
        }
        async function start(){showStatus('正在連接圖庫','請稍候…');try{const data=await json('/api/libraries');libraries=Array.isArray(data.libraries)?data.libraries:[];if(!libraries.length){showStatus('沒有已分享圖庫','請在 Mac 上選擇要分享的圖庫。');return}await restoreSavedView(savedView())}catch(_){restoringScroll=false;showStatus('暫時無法連接','請確認 Mac 上的 Web Gallery 正在運行。',start)}}
        start();
      })();
      </script>
    </body>
    </html>
    """#
}
