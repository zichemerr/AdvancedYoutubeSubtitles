(function(){
    const ARRAY_PREFIXES=['yt_seen_','yt_learned_','yt_player_videos_','yt_texts_'];
    const POS_PREFIX='yt_pos_';
    const SCALAR_KEYS=['yt_learn_lang','yt_player_target_lang','yt_theme'];
    const ALL_PREFIXES=[...ARRAY_PREFIXES,POS_PREFIX];
    let lastSyncTs=0;
    let syncTimer=null;
    let syncing=false;
    let initializing=true;

    function isSyncKey(k){
        return ALL_PREFIXES.some(p=>k.startsWith(p))||SCALAR_KEYS.includes(k);
    }

    function categorizeKey(k){
        for(const p of ARRAY_PREFIXES)if(k.startsWith(p))return{cat:'array',prefix:p,lang:k.slice(p.length)};
        if(k.startsWith(POS_PREFIX))return{cat:'position',id:k.slice(POS_PREFIX.length)};
        if(SCALAR_KEYS.includes(k))return{cat:'settings',key:k};
        return null;
    }

    function collectState(){
        const state={seen:{},learned:{},videos:{},texts:{},positions:{},settings:{}};
        for(let i=0;i<localStorage.length;i++){
            const k=localStorage.key(i);
            const info=categorizeKey(k);
            if(!info)continue;
            try{
                if(info.cat==='array'){
                    const arr=JSON.parse(localStorage.getItem(k)||'[]');
                    if(info.prefix==='yt_seen_')state.seen[info.lang]=arr;
                    else if(info.prefix==='yt_learned_')state.learned[info.lang]=arr;
                    else if(info.prefix==='yt_player_videos_')state.videos[info.lang]=arr;
                    else if(info.prefix==='yt_texts_')state.texts[info.lang]=arr;
                }else if(info.cat==='position'){
                    const v=parseInt(localStorage.getItem(k)||'0',10);
                    if(v>0)state.positions[info.id]=v;
                }else if(info.cat==='settings'){
                    state.settings[info.key]=localStorage.getItem(k);
                }
            }catch{}
        }
        return state;
    }

    function mergeArray(existing,incoming){
        if(!Array.isArray(existing))existing=[];
        if(!Array.isArray(incoming))incoming=[];
        return[...new Set([...existing,...incoming])];
    }

    function mergeItemArray(existing,incoming){
        if(!Array.isArray(existing))existing=[];
        if(!Array.isArray(incoming))incoming=[];
        const map={};
        existing.forEach(item=>{if(item&&item.id)map[item.id]=item;});
        incoming.forEach(item=>{if(item&&item.id)map[item.id]=item;});
        return Object.values(map);
    }

    function applyServerState(server){
        if(!server)return;
        for(const lang in server.seen||{}){
            const key='yt_seen_'+lang;
            const local=JSON.parse(localStorage.getItem(key)||'[]');
            localStorage.setItem(key,JSON.stringify(mergeArray(local,server.seen[lang])));
        }
        for(const lang in server.learned||{}){
            const key='yt_learned_'+lang;
            const local=JSON.parse(localStorage.getItem(key)||'[]');
            localStorage.setItem(key,JSON.stringify(mergeArray(local,server.learned[lang])));
        }
        for(const lang in server.videos||{}){
            const key='yt_player_videos_'+lang;
            const local=JSON.parse(localStorage.getItem(key)||'[]');
            localStorage.setItem(key,JSON.stringify(mergeItemArray(local,server.videos[lang])));
        }
        for(const lang in server.texts||{}){
            const key='yt_texts_'+lang;
            const local=JSON.parse(localStorage.getItem(key)||'[]');
            localStorage.setItem(key,JSON.stringify(mergeItemArray(local,server.texts[lang])));
        }
        for(const id in server.positions||{}){
            const key='yt_pos_'+id;
            const local=parseInt(localStorage.getItem(key)||'0',10);
            const remote=server.positions[id]||0;
            if(remote>local)localStorage.setItem(key,String(remote));
        }
        if(server.settings){
            for(const k in server.settings){
                if(SCALAR_KEYS.includes(k)){
                    if(!localStorage.getItem(k)&&server.settings[k]){
                        localStorage.setItem(k,server.settings[k]);
                    }
                }
            }
        }
    }

    function doSync(){
        if(syncing)return;
        syncing=true;
        const state=collectState();
        state.timestamp=lastSyncTs;
        fetch('/api/sync',{
            method:'POST',
            headers:{'Content-Type':'application/json'},
            body:JSON.stringify(state)
        }).then(r=>r.json()).then(d=>{
            if(d&&d.timestamp)lastSyncTs=d.timestamp;
            if(d&&d.merged){
                initializing=true;
                applyServerState(d.merged);
                initializing=false;
            }
            syncing=false;
        }).catch(()=>{syncing=false;});
    }

    function scheduleSync(){
        if(syncTimer)clearTimeout(syncTimer);
        syncTimer=setTimeout(doSync,1500);
    }

    setInterval(doSync,30000);

    const origSetItem=Storage.prototype.setItem;
    const origRemoveItem=Storage.prototype.removeItem;

    Storage.prototype.setItem=function(k,v){
        origSetItem.call(this,k,v);
        if(!initializing&&isSyncKey(k))scheduleSync();
    };
    Storage.prototype.removeItem=function(k){
        origRemoveItem.call(this,k);
        if(!initializing&&isSyncKey(k))scheduleSync();
    };

    window.AppSync={ready:fetch('/api/sync').then(r=>r.json()).then(server=>{
        if(server&&server.timestamp)lastSyncTs=server.timestamp;
        initializing=true;
        applyServerState(server);
        initializing=false;
    }).catch(()=>{}).then(()=>{})};

    window.addEventListener('beforeunload',()=>{
        const state=collectState();
        state.timestamp=lastSyncTs;
        navigator.sendBeacon('/api/sync',new Blob([JSON.stringify(state)],{type:'application/json'}));
    });
})();
