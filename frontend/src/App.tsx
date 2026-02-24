import React, { useState, useEffect, useRef } from 'react';
import ReactMarkdown from 'react-markdown';
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter';
import { vscDarkPlus } from 'react-syntax-highlighter/dist/esm/styles/prism';// --- Icons (Inline SVGs) ---
const IconSettings = () => <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33h.09a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>;
const IconMoon = () => <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>;
const IconSun = () => <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>;
const IconFolder = () => <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>;
const IconFile = () => <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><polyline points="13 2 13 9 20 9"/></svg>;
const IconPin = () => <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="12" y1="17" x2="12" y2="22"/><path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.68V6a3 3 0 0 0-3-3 3 3 0 0 0-3 3v4.68a2 2 0 0 1-1.11 1.87l-1.78.9A2 2 0 0 0 5 15.24Z"/></svg>;
const IconClose = () => <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>;
const IconInfo = () => <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>;
const IconDownload = () => <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>;
const IconCopy = () => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>;
const IconDelete = () => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><line x1="10" y1="11" x2="10" y2="17"/><line x1="14" y1="11" x2="14" y2="17"/></svg>;
const IconCheck = () => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="20 6 9 17 4 12"/></svg>;
const IconChevronUp = () => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="18 15 12 9 6 15"/></svg>;
const IconChevronDown = () => <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="6 9 12 15 18 9"/></svg>;


// --- Types ---
type FileNode = { name: string; type: 'file' | 'folder'; path: string; children?: FileNode[]; };
type TabData = { id: string; title: string; path: string; type: 'file' | 'folder'; pinned: boolean; content?: string; };
type ChatMessage = { role: 'user' | 'assistant'; content: string; sources?: any[] };

// --- Main App ---
export default function App() {
  const [theme, setTheme] = useState<'light' | 'dark'>('light');
  const [showSettings, setShowSettings] = useState(false);
  const [config, setConfig] = useState({ pkm_root: '', llm_base_url: '', llm_model: '', llm_api_token: '', system_prompt: '', chunk_size: 1000, chunk_overlap: 200, top_k: 5 });
  const [settingsTab, setSettingsTab] = useState<'general' | 'ai' | 'indexing'>('general');
  const [configStatus, setConfigStatus] = useState('');
  const [isIndexing, setIsIndexing] = useState(false);
  const [indexStatus, setIndexStatus] = useState('');

  const [backendStatus, setBackendStatus] = useState<{llm: string, vectordb: string, chunks: number, logs: string[]}>({llm: 'Unknown', vectordb: 'Unknown', chunks: 0, logs: []});
  const [showLogs, setShowLogs] = useState(false);

  const [files, setFiles] = useState<FileNode[]>([]);
  const [searchQuery, setSearchQuery] = useState('');
  const [expandedFolders, setExpandedFolders] = useState<Set<string>>(new Set());
  const [chatHeight, setChatHeight] = useState(350);
  const [isChatMinimized, setIsChatMinimized] = useState(false);
  const [isDragging, setIsDragging] = useState(false);
  const isResizing = useRef(false);

  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (!isResizing.current) return;
      const newHeight = window.innerHeight - e.clientY;
      if (newHeight >= 40 && newHeight <= window.innerHeight - 200) {
        setChatHeight(newHeight);
        if (newHeight > 40) setIsChatMinimized(false);
        else setIsChatMinimized(true);
      }
    };

    const handleMouseUp = () => {
      isResizing.current = false;
      setIsDragging(false);
      document.body.style.cursor = 'default';
      const handle = document.querySelector('.chat-resize-handle');
      if (handle) handle.classList.remove('active');
    };

    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, []);

  const startResizing = (e: React.MouseEvent) => {
    e.preventDefault();
    isResizing.current = true;
    setIsDragging(true);
    document.body.style.cursor = 'row-resize';
    (e.currentTarget as HTMLElement).classList.add('active');
  };

  const toggleChatMinimize = () => {
    setIsChatMinimized(!isChatMinimized);
  };

  const toggleFolder = (e: React.MouseEvent, path: string) => {
    e.stopPropagation();
    setExpandedFolders(prev => {
      const next = new Set(prev);
      if(next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  const [tabs, setTabs] = useState<TabData[]>(() => {
    const stored = localStorage.getItem('dido_pinned_tabs');
    if (stored) {
       try { return JSON.parse(stored); } catch(e) {}
    }
    return [];
  });

  useEffect(() => {
     const pinned = tabs.filter(t => t.pinned).map(({ content, ...rest }) => rest);
     localStorage.setItem('dido_pinned_tabs', JSON.stringify(pinned));
  }, [tabs]);
  const [activeTabId, setActiveTabId] = useState<string | null>(() => {
    const stored = localStorage.getItem('dido_pinned_tabs');
    if (stored) {
       try { 
         const parsed = JSON.parse(stored); 
         if (parsed.length > 0) return parsed[0].id;
       } catch(e) {}
    }
    return null;
  });

  // Per Tab Chats
  const [chats, setChats] = useState<Record<string, ChatMessage[]>>({});
  
  // Metadata state
  const [showMetadata, setShowMetadata] = useState(false);
  const [tabMetadata, setTabMetadata] = useState<Record<string, any>>({});
  const [editMetadata, setEditMetadata] = useState<Record<string, any> | null>(null);
  const activeTab = tabs.find(t => t.id === activeTabId);

  // Initialize theme and load config
  useEffect(() => {
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const storedTheme = localStorage.getItem('theme') || (prefersDark ? 'dark' : 'light');
    setTheme(storedTheme as 'light' | 'dark');
    document.documentElement.setAttribute('data-theme', storedTheme);

    fetchConfig();
    fetchFiles();
    
    const interval = setInterval(() => {
       fetchStatus();
    }, 3000);
    return () => clearInterval(interval);
  }, []);

  const [modelsList, setModelsList] = useState<{name: string, is_vlm: boolean}[]>([]);
  const [fetchingModels, setFetchingModels] = useState(false);

  useEffect(() => {
    if (showSettings && config.llm_base_url) {
       const fetchModels = async () => {
         setFetchingModels(true);
         try {
           const res = await fetch('/api/models', {
             method: 'POST',
             headers: {'Content-Type': 'application/json'},
             body: JSON.stringify({ url: config.llm_base_url, token: config.llm_api_token })
           });
           if (res.ok) {
             const data = await res.json();
             setModelsList(data);
           } else {
             setModelsList([]);
           }
         } catch (e) {
           setModelsList([]);
         }
         setFetchingModels(false);
       };
       const timer = setTimeout(fetchModels, 500);
       return () => clearTimeout(timer);
    }
  }, [config.llm_base_url, config.llm_api_token, showSettings]);

  const fetchStatus = async () => {
    try {
      const res = await fetch('/api/status');
      if(res.ok) {
        setBackendStatus(await res.json());
      }
      
      const idxRes = await fetch('/api/index/status');
      if (idxRes.ok) {
        const idxData = await idxRes.json();
        setIsIndexing(idxData.is_indexing);
        setIndexStatus(idxData.detail);
      }
    } catch(e) {}
  };

  const toggleTheme = () => {
    const newTheme = theme === 'light' ? 'dark' : 'light';
    setTheme(newTheme);
    localStorage.setItem('theme', newTheme);
    document.documentElement.setAttribute('data-theme', newTheme);
  };

  const fetchConfig = async () => {
    try {
      const res = await fetch('/api/config');
      const data = await res.json();
      setConfig(data);
    } catch (err) { }
  };

  const fetchFiles = async () => {
    try {
      const res = await fetch('/api/files');
      if(res.ok) {
        setFiles(await res.json());
      }
    } catch(e) {}
  };

  const triggerIndex = async () => {
    setIsIndexing(true); setIndexStatus('Starting indexing...');
    try {
      const res = await fetch('/api/index', { method: 'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({root_path: config.pkm_root})});
      const data = await res.json();
      if(!res.ok) throw new Error(data.detail);
      setIndexStatus(data.detail || 'Indexing started...');
    } catch(e: any) { setIndexStatus('Error: ' + e.message); setIsIndexing(false); }
  };

  const saveConfig = async () => {
    try {
      const res = await fetch('/api/config', { method: 'PUT', headers:{'Content-Type':'application/json'}, body: JSON.stringify(config) });
      if(!res.ok) throw new Error('Failed to save config');
      setConfigStatus('Config saved.');
      fetchFiles();
      setTimeout(() => setConfigStatus(''), 3000);
    } catch(e: any) { setConfigStatus('Error: ' + e.message); }
  };

  // Tab Management
  const openPath = async (node: FileNode) => {
    let exist = tabs.find(t => t.path === node.path);
    if(exist) {
      setActiveTabId(exist.id);
      return;
    }
    const id = Date.now().toString();
    const newTab: TabData = { id, title: node.name, path: node.path, type: node.type, pinned: false };
    
    // Fetch content if file
    if(node.type === 'file') {
      try {
        const res = await fetch('/api/file/content', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({path: node.path}) });
        if(res.ok) {
          const data = await res.json();
          newTab.content = data.content;
        } else { newTab.content = "// Unable to load content"; }
      } catch(e) { newTab.content = "// Error loading file"; }
    }
    setTabs(prev => [...prev, newTab]);
    setActiveTabId(id);
    
    // Auto-fetch metadata (simulated or real if API supports it, for now we just parse locally or fetch query)
    // You can do a dummy query filter by path to see if chroma has metadata
    fetchMetadataForPath(node.path, id);
  };

  const fetchMetadataForPath = async (path: string, tabId: string) => {
    // A trick to get metadata for a specific file from the vector store:
    // Ask a dummy question and filter by path. It's an approximation.
    try {
      const res = await fetch('/api/query', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ query: 'summarize', filters: {path}, top_k: 1 })
      });
      if(res.ok) {
         const data = await res.json();
         if(data.sources && data.sources.length > 0) {
            setTabMetadata(prev => ({...prev, [tabId]: data.sources[0].metadata}));
         } else {
            setTabMetadata(prev => ({...prev, [tabId]: { path, status: 'Not indexed' }}));
         }
      }
    } catch (e) {}
  };

  // Restore content and metadata for initially pinned tabs
  useEffect(() => {
     tabs.forEach(tab => {
        if (!tab.content && tab.type === 'file') {
             fetch('/api/file/content', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({path: tab.path}) })
                .then(res => res.ok ? res.json() : null)
                .then(data => {
                   if(data) setTabs(prev => prev.map(t => t.id === tab.id ? {...t, content: data.content} : t));
                });
        }
        fetchMetadataForPath(tab.path, tab.id);
     });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const closeTab = (e: React.MouseEvent, id: string) => {
    e.stopPropagation();
    const tab = tabs.find(t => t.id === id);
    if(tab?.pinned) return;
    setTabs(prev => prev.filter(t => t.id !== id));
    if(activeTabId === id) {
      const remaining = tabs.filter(t => t.id !== id);
      setActiveTabId(remaining.length > 0 ? remaining[remaining.length - 1].id : null);
    }
  };

  const togglePin = (e: React.MouseEvent, id: string) => {
    e.stopPropagation();
    setTabs(prev => prev.map(t => t.id === id ? {...t, pinned: !t.pinned} : t));
  };

  // Search filter
  const filterNodes = (nodes: FileNode[], query: string): FileNode[] => {
    if(!query) return nodes;
    return nodes.map(n => {
      if(n.type === 'folder' && n.children) {
        const filteredChildren = filterNodes(n.children, query);
        if(filteredChildren.length > 0 || n.name.toLowerCase().includes(query.toLowerCase())) {
          return { ...n, children: filteredChildren };
        }
        return null;
      }
      if(n.name.toLowerCase().includes(query.toLowerCase())) return n;
      return null;
    }).filter(Boolean) as FileNode[];
  };

  const filteredFiles = filterNodes(files, searchQuery);

  const renderTree = (nodes: FileNode[], level = 0) => {
    return nodes.map(n => {
      const isExpanded = expandedFolders.has(n.path);
      return (
      <React.Fragment key={n.path}>
        <div 
          className={`tree-node ${activeTab?.path === n.path ? 'active' : ''}`} 
          style={{ paddingLeft: `${ level * 15 + 15}px`, display: 'flex', alignItems: 'center' }}
          onClick={(e) => {
            if (n.type === 'folder') toggleFolder(e, n.path);
            openPath(n);
          }}
        >
          {n.type === 'folder' ? (
             <div className="node-icon" style={{marginRight: '6px', opacity: 0.6, fontSize: '0.8em', width: '12px', textAlign: 'center'}}>
               {isExpanded ? '▼' : '▶'}
             </div>
          ) : (
             <div style={{width: '18px'}} />
          )}
          <div className="node-icon">{n.type === 'folder' ? <IconFolder /> : <IconFile />}</div>
          <span className="node-name">{n.name}</span>
        </div>
        {n.type === 'folder' && n.children && isExpanded && renderTree(n.children, level + 1)}
      </React.Fragment>
    )});
  };

  const renderFileViewer = () => {
    if (!activeTab) return null;
    if (activeTab.type === 'folder') {
        return (
            <div className="file-viewer-content" style={{textAlign:'center', paddingTop:'40px', color:'var(--text-tertiary)'}}>
                <IconFolder /><br/>
                Folder Selected: {activeTab.path}<br/>
                You can ask questions about contents of this folder using the chat below.
            </div>
        );
    }

    const pathLower = activeTab.path.toLowerCase();
    const isOffice = /\.(docx|pptx|xlsx|rtf)$/.test(pathLower);
    const isPdf = pathLower.endsWith('.pdf');
    const isMd = pathLower.endsWith('.md');
    const isXmlOrYaml = /\.(xml|yaml|yml)$/.test(pathLower);

    if (isOffice) {
        return (
            <div className="file-viewer-content" style={{textAlign:'center', paddingTop:'40px', color:'var(--text-tertiary)'}}>
                <IconFile /><br/>
                Document Selected: {activeTab.path}<br/>
                You can ask questions about contents of this document using the chat below, or download it using the button above.
            </div>
        );
    }

    if (isPdf) {
        return (
            <div className="file-viewer-content" style={{padding: 0, overflow: 'hidden', height: '100%'}}>
                <iframe src={`/api/file/raw?path=${encodeURIComponent(activeTab.path)}`} style={{width: '100%', height: '100%', border: 'none'}} title="PDF Viewer" />
            </div>
        );
    }
    
    if (isMd) {
        return (
            <div className="file-viewer-content" style={{padding: '20px', overflowY: 'auto', lineHeight: '1.6'}}>
                <ReactMarkdown>{activeTab.content || ''}</ReactMarkdown>
            </div>
        );
    }

    if (isXmlOrYaml) {
        const lang = pathLower.endsWith('.xml') ? 'xml' : 'yaml';
        return (
            <div className="file-viewer-content" style={{padding: '0', overflowY: 'auto', background: '#1e1e1e'}}>
                <SyntaxHighlighter language={lang} style={vscDarkPlus} showLineNumbers customStyle={{margin:0, border:'none', borderRadius:0, height:'100%'}}>
                    {activeTab.content || ''}
                </SyntaxHighlighter>
            </div>
        );
    }

    return (
        <div className="file-viewer-content" style={{whiteSpace: 'pre-wrap', padding: '20px', fontFamily: 'monospace'}}>
            {activeTab.content || 'Loading...'}
        </div>
    );
  };

  // Chat logic
  const [chatInput, setChatInput] = useState('');
  const [isSending, setIsSending] = useState(false);
  const [copiedMsgId, setCopiedMsgId] = useState<string | null>(null);
  const chatEndRef = useRef<HTMLDivElement>(null);

  const handleCopy = (content: string, msgId: string) => {
    navigator.clipboard.writeText(content);
    setCopiedMsgId(msgId);
    setTimeout(() => setCopiedMsgId(null), 2000);
  };

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [chats, activeTabId]);

  const deleteMessage = (tabId: string, index: number) => {
    setChats(prev => {
       const tabChats = prev[tabId] || [];
       if (index < 0 || index >= tabChats.length) return prev;
       const newChats = [...tabChats];
       newChats.splice(index, 1);
       return { ...prev, [tabId]: newChats };
    });
  };

  const sendMessage = async () => {
    if(!chatInput.trim() || !activeTabId || !activeTab) return;
    const msg = chatInput.trim();
    setChatInput('');
    const newChat: ChatMessage = { role: 'user', content: msg };
    setChats(prev => ({...prev, [activeTabId]: [...(prev[activeTabId] || []), newChat]}));
    
    setIsSending(true);
    try {
      const res = await fetch('/api/query', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: msg, filters: { path: activeTab.path } })
      });
      const data = await res.json();
      if(res.ok) {
        setChats(prev => ({
          ...prev, 
          [activeTabId]: [...(prev[activeTabId] || []), { role: 'assistant', content: data.answer, sources: data.sources }]
        }));
      } else { 
        setChats(prev => ({
          ...prev, 
          [activeTabId]: [...(prev[activeTabId] || []), { role: 'assistant', content: `**Error**: ${data.detail || 'An unexpected error occurred. Please try again.'}` }]
        }));
      }
    } catch(e: any) {
      setChats(prev => ({
        ...prev, 
        [activeTabId]: [...(prev[activeTabId] || []), { role: 'assistant', content: `**Error**: Cannot connect to the backend. Please ensure the server is running. (${e.message})` }]
      }));
    }
    setIsSending(false);
  };

  return (
    <>
      <header className="app-header">
        <div className="brand">Dido Workspace</div>
        <div className="header-actions">
          <button className="icon-btn" onClick={toggleTheme} title="Toggle Theme">
            {theme === 'dark' ? <IconSun /> : <IconMoon />}
          </button>
          <button className="icon-btn" onClick={() => setShowSettings(true)} title="Settings">
            <IconSettings />
          </button>
        </div>
      </header>

      <div className="app-main">
        {/* Sidebar */}
        <div className="sidebar">
          <div className="sidebar-header">
            <input 
              type="text" 
              className="search-input" 
              placeholder="Filter files..." 
              value={searchQuery}
              onChange={e => setSearchQuery(e.target.value)}
            />
          </div>
          <div className="tree-view">
            {renderTree(filteredFiles)}
          </div>
        </div>

        {/* Main Workspace Area */}
        <div className="content-area">
          {tabs.length > 0 ? (
            <>
              {/* Tab Bar */}
              <div className="tabs-bar">
                {tabs.sort((a,b) => (a.pinned === b.pinned ? 0 : a.pinned ? -1 : 1)).map(tab => (
                  <div key={tab.id} className={`tab ${tab.id === activeTabId ? 'active' : ''}`} onClick={() => setActiveTabId(tab.id)}>
                    {tab.pinned && <IconPin />}
                    <span>{tab.title}</span>
                    <div className="tab-actions" style={{display:'flex', gap:'4px', marginLeft:'8px'}}>
                      <div className="tab-pin" onClick={e => togglePin(e, tab.id)}><IconPin /></div>
                      {!tab.pinned && <div className="tab-close" onClick={e => closeTab(e, tab.id)}><IconClose /></div>}
                    </div>
                  </div>
                ))}
              </div>

              {/* Active Tab View */}
              <div className="content-body">
                {activeTab && (
                  <div className="file-viewer">
                     <div style={{display:'flex', justifyContent:'space-between', marginBottom:'10px'}}>
                        <h3 style={{margin:0, color:'var(--text-secondary)', fontWeight: 500}}>{activeTab.path}</h3>
                        <div style={{display:'flex', gap:'5px'}}>
                           {activeTab.type === 'file' && (
                              <a href={`/api/file/raw?path=${encodeURIComponent(activeTab.path)}`} target="_blank" rel="noreferrer" className="icon-btn" style={{background:'var(--bg-secondary)', textDecoration: 'none', display: 'flex', alignItems: 'center', justifyContent: 'center'}} title="Download Original File">
                                 <IconDownload />
                              </a>
                           )}
                           <button className="icon-btn" style={{background:'var(--bg-secondary)'}} onClick={() => setShowMetadata(!showMetadata)}>
                              <IconInfo />
                           </button>
                        </div>
                     </div>
                     {renderFileViewer()}
                  </div>
                )}

                {/* Chat Panel */}
                <div className={`chat-panel ${isChatMinimized ? 'minimized' : ''} ${isDragging ? 'dragging' : ''}`} style={{ height: isChatMinimized ? undefined : `${chatHeight}px` }}>
                  <div className="chat-resize-handle" onMouseDown={startResizing} />
                  <div className="chat-header" onClick={toggleChatMinimize}>
                     <span>Chat with {activeTab?.title}</span>
                     <div className="icon-btn" style={{width:'24px', height:'24px'}}>
                        {isChatMinimized ? <IconChevronUp /> : <IconChevronDown />}
                     </div>
                  </div>
                  <div className="chat-messages">
                     {(chats[activeTabId!] || []).length === 0 && (
                        <div style={{textAlign:'center', color:'var(--text-tertiary)', marginTop:'auto', marginBottom:'auto'}}>
                           Ask a question to explore the contents of {activeTab?.title}.
                        </div>
                     )}
                     {(chats[activeTabId!] || []).map((msg, i) => {
                       const msgId = `${activeTabId}-${i}`;
                       return (
                       <div key={i} className={`message ${msg.role}`}>
                         {msg.role === 'assistant' && (
                           <div className="message-actions">
                             <button className="icon-btn" onClick={() => handleCopy(msg.content, msgId)} title="Copy">
                               {copiedMsgId === msgId ? <IconCheck /> : <IconCopy />}
                             </button>
                             <button className="icon-btn" onClick={() => deleteMessage(activeTabId!, i)} title="Delete">
                               <IconDelete />
                             </button>
                           </div>
                         )}
                         {msg.role === 'assistant' ? (
                           <div className="markdown-body">
                             <ReactMarkdown>{msg.content}</ReactMarkdown>
                           </div>
                         ) : (
                           <div>{msg.content}</div>
                         )}
                         {msg.sources && msg.sources.length > 0 && (
                            <div className="source-badges">
                               {msg.sources.map((src: any, j: number) => (
                                  <span key={j} className="source-badge" title={src.snippet.substring(0, 100) + '...'}>
                                    📄 {src.metadata.path?.split('/').pop() || 'Unknown source'}
                                  </span>
                               ))}
                            </div>
                         )}
                       </div>
                     )})}
                     {isSending && (
                        <div className="message assistant loading">
                           <div className="typing-indicator">
                              <span></span><span></span><span></span>
                           </div>
                        </div>
                     )}
                     <div ref={chatEndRef} />
                  </div>
                  <div className="chat-input-area">
                    <input 
                      type="text" 
                      className="chat-input" 
                      placeholder="Ask anything..." 
                      value={chatInput}
                      onChange={e => setChatInput(e.target.value)}
                      onKeyDown={e => e.key === 'Enter' && sendMessage()}
                      disabled={isSending}
                    />
                    <button className="btn-send" onClick={sendMessage} disabled={isSending}>
                      {isSending ? '...' : 'Send'}
                    </button>
                  </div>
                </div>

                {/* Metadata Collapsible Panel */}
                <div className={`metadata-panel ${showMetadata ? 'open' : ''}`}>
                   <div className="metadata-header">
                      Metadata
                      <div style={{display:'flex', gap:'5px', marginLeft:'auto'}}>
                         {editMetadata ? (
                            <>
                               <button className="icon-btn" style={{fontSize:'12px', padding:'2px 6px', borderRadius:'4px', background:'var(--bg-tertiary)'}} onClick={async () => {
                                  try {
                                     const res = await fetch('/api/metadata', {
                                        method: 'PUT',
                                        headers: { 'Content-Type': 'application/json' },
                                        body: JSON.stringify({ path: activeTab?.path, metadata: editMetadata })
                                     });
                                     if(res.ok) {
                                        setTabMetadata(prev => ({...prev, [activeTabId!]: editMetadata}));
                                        setEditMetadata(null);
                                     } else {
                                        const err = await res.json();
                                        alert("Error saving metadata: " + err.detail);
                                     }
                                  } catch (e: any) { alert("Error: " + e.message); }
                               }}>Save</button>
                               <button className="icon-btn" style={{fontSize:'12px', padding:'2px 6px', borderRadius:'4px'}} onClick={() => setEditMetadata(null)}>Cancel</button>
                            </>
                         ) : (
                            <button className="icon-btn" style={{fontSize:'12px', padding:'2px 6px', borderRadius:'4px', background:'var(--bg-tertiary)'}} onClick={() => setEditMetadata({...tabMetadata[activeTabId!]})}>Edit</button>
                         )}
                         <button className="icon-btn" onClick={() => setShowMetadata(false)}><IconClose /></button>
                      </div>
                   </div>
                   <div className="metadata-body">
                      {editMetadata ? (
                         Object.entries(editMetadata).map(([key, val]) => (
                            <div key={key} className="metadata-item" style={{flexDirection: 'column', alignItems: 'flex-start'}}>
                               <span className="label" style={{marginBottom: '4px'}}>{key}</span>
                               <input 
                                  className="search-input" 
                                  style={{padding: '4px 8px', fontSize: '12px', width: '100%', boxSizing: 'border-box'}} 
                                  value={val === null || val === undefined ? "" : Array.isArray(val) ? val.join(', ') : String(val)} 
                                  onChange={e => {
                                      let newVal: any = e.target.value;
                                      if (key === 'tags') newVal = newVal.split(',').map((s: string) => s.trim()).filter(Boolean);
                                      setEditMetadata({...editMetadata, [key]: newVal});
                                  }} 
                                  disabled={key === 'path' || key === 'extension'} 
                               />
                            </div>
                         ))
                      ) : tabMetadata[activeTabId!] ? (
                         Object.entries(tabMetadata[activeTabId!]).map(([key, val]) => (
                            <div key={key} className="metadata-item">
                               <span className="label">{key}</span>
                               <span className="value">{Array.isArray(val) ? val.join(', ') : String(val)}</span>
                            </div>
                         ))
                      ) : (
                         <div style={{color:'var(--text-tertiary)'}}>No metadata loaded.</div>
                      )}
                   </div>
                </div>

              </div>
            </>
          ) : (
            <div style={{display:'flex', flex:1, alignItems:'center', justifyContent:'center', color:'var(--text-tertiary)', flexDirection:'column', gap:'15px'}}>
               <IconFolder />
               <div>Select a file or folder from the sidebar to begin.</div>
            </div>
          )}
        </div>
      </div>

      {/* Thin Status Bar */}
      <div className="status-bar" onClick={() => setShowLogs(!showLogs)}>
         <div className="status-item">LLM: {backendStatus.llm}</div>
         <div className="status-item">VectorDB: {backendStatus.vectordb}</div>
         <div className="status-item">Indexed Chunks: {backendStatus.chunks}</div>
         <div style={{flex:1}}></div>
         <div className="status-item logs-toggle">{showLogs ? 'Hide Logs' : 'View Logs'}</div>
      </div>

      {/* Logs Panel */}
      {showLogs && (
         <div className="logs-panel">
            <div className="logs-header">Backend Logs</div>
            <div className="logs-content">
               {backendStatus.logs.length === 0 && <div style={{color:'var(--text-tertiary)'}}>No logs available...</div>}
               {backendStatus.logs.map((log, i) => (
                  <div key={i} className="log-line">{log}</div>
               ))}
            </div>
         </div>
      )}

      {/* Settings Modal */}
      {showSettings && (
        <div className="modal-overlay" onClick={() => setShowSettings(false)}>
          <div className="modal-content" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <h2>Settings & Indexing</h2>
              <button className="icon-btn" onClick={() => setShowSettings(false)}><IconClose /></button>
            </div>
            
            <div className="settings-tabs" style={{display:'flex', borderBottom:'1px solid var(--border-color)', marginBottom:'15px', padding:'0 20px'}}>
               <button className={`tab-btn ${settingsTab === 'general' ? 'active' : ''}`} onClick={() => setSettingsTab('general')} style={{background:'none', border:'none', padding:'10px 15px', color: settingsTab === 'general' ? 'var(--text-primary)' : 'var(--text-tertiary)', borderBottom: settingsTab === 'general' ? '2px solid var(--text-primary)' : '2px solid transparent', cursor:'pointer'}}>General</button>
               <button className={`tab-btn ${settingsTab === 'ai' ? 'active' : ''}`} onClick={() => setSettingsTab('ai')} style={{background:'none', border:'none', padding:'10px 15px', color: settingsTab === 'ai' ? 'var(--text-primary)' : 'var(--text-tertiary)', borderBottom: settingsTab === 'ai' ? '2px solid var(--text-primary)' : '2px solid transparent', cursor:'pointer'}}>AI Prompts</button>
               <button className={`tab-btn ${settingsTab === 'indexing' ? 'active' : ''}`} onClick={() => setSettingsTab('indexing')} style={{background:'none', border:'none', padding:'10px 15px', color: settingsTab === 'indexing' ? 'var(--text-primary)' : 'var(--text-tertiary)', borderBottom: settingsTab === 'indexing' ? '2px solid var(--text-primary)' : '2px solid transparent', cursor:'pointer'}}>Indexing</button>
            </div>
            
            <div className="modal-body" style={{paddingTop: '0'}}>
              {settingsTab === 'general' && (
                 <>
                  <div className="form-group">
                    <label>PKM Root Path</label>
                    <input value={config.pkm_root} onChange={e => setConfig({...config, pkm_root: e.target.value})} />
                  </div>
                  <div className="form-group">
                    <label>LLM Base URL</label>
                    <input value={config.llm_base_url} onChange={e => setConfig({...config, llm_base_url: e.target.value})} />
                  </div>
                  <div className="form-group">
                    <label>API TOKEN (Optional)</label>
                    <input type="password" value={config.llm_api_token || ''} onChange={e => setConfig({...config, llm_api_token: e.target.value})} placeholder="Leave blank if not needed" />
                  </div>
                  <div className="form-group">
                    <label>LLM Model</label>
                    {fetchingModels ? (
                       <div style={{color: 'var(--text-tertiary)', fontSize: '13px', padding: '8px 0'}}>Loading models...</div>
                    ) : modelsList.length > 0 ? (
                       <select value={config.llm_model} onChange={e => setConfig({...config, llm_model: e.target.value})} style={{width: '100%', padding: '8px', background: 'var(--bg-tertiary)', color: 'var(--text-primary)', border: '1px solid var(--border-color)', borderRadius: '4px'}}>
                         {modelsList.map(m => (
                            <option key={m.name} value={m.name}>{m.name} {m.is_vlm ? '(VLM)' : ''}</option>
                         ))}
                       </select>
                    ) : (
                       <input value={config.llm_model} onChange={e => setConfig({...config, llm_model: e.target.value})} placeholder="Enter model name" />
                    )}
                  </div>
                  
                  <div style={{marginTop: '10px', fontSize: '13px', color: 'var(--text-tertiary)', lineHeight: '1.4'}}>
                      {modelsList.find(m => m.name === config.llm_model)?.is_vlm ? (
                          <div><strong>VLM Selected:</strong> You can query all documents including PDFs, Office files, and images.</div>
                      ) : (
                          <div><strong>LLM Selected:</strong> Only indexed text chunks and simple text files will be queried.</div>
                      )}
                  </div>
                 </>
              )}
              
              {settingsTab === 'ai' && (
                 <>
                  <div className="form-group">
                    <label>System Prompt</label>
                    <textarea 
                       value={config.system_prompt || ''} 
                       onChange={e => setConfig({...config, system_prompt: e.target.value})} 
                       style={{width: '100%', minHeight: '100px', padding: '8px', background: 'var(--bg-secondary)', color: 'var(--text-primary)', border: '1px solid var(--border-color)', borderRadius: '4px', resize: 'vertical'}}
                    />
                    <div style={{fontSize: '11px', color: 'var(--text-tertiary)', marginTop: '4px'}}>This prompt defines how the AI behaves and formats its answers.</div>
                  </div>
                  <div className="form-group">
                    <label>Top K Search Results</label>
                    <input type="number" min="1" max="20" value={config.top_k || 5} onChange={e => setConfig({...config, top_k: parseInt(e.target.value) || 5})} />
                    <div style={{fontSize: '11px', color: 'var(--text-tertiary)', marginTop: '4px'}}>Number of chunks retrieved from the knowledge base for standard queries.</div>
                  </div>
                 </>
              )}

              {settingsTab === 'indexing' && (
                 <>
                  <div className="form-group">
                    <label>Chunk Size</label>
                    <input type="number" value={config.chunk_size || 1000} onChange={e => setConfig({...config, chunk_size: parseInt(e.target.value) || 1000})} />
                  </div>
                  <div className="form-group">
                    <label>Chunk Overlap</label>
                    <input type="number" value={config.chunk_overlap || 200} onChange={e => setConfig({...config, chunk_overlap: parseInt(e.target.value) || 200})} />
                  </div>
                  <div style={{display:'flex', gap:'10px', marginTop:'20px'}}>
                     <button className="btn" onClick={triggerIndex} disabled={isIndexing} style={{background:'var(--bg-tertiary)', color:'var(--text-primary)', width: '100%'}}>
                       {isIndexing ? 'Indexing...' : 'Re-index Now'}
                     </button>
                  </div>
                 </>
              )}
              
              <div style={{display:'flex', gap:'10px', marginTop:'20px', paddingTop:'15px', borderTop:'1px solid var(--border-color)'}}>
                 <button className="btn" onClick={saveConfig}>Save Config</button>
              </div>

              {configStatus && <div className="status-msg success">{configStatus}</div>}
              {indexStatus && <div className="status-msg info">{indexStatus}</div>}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
