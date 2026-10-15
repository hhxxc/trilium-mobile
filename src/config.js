// 全局默认配置（可在 App「设置」页修改，存 localStorage）
// 默认走 ddnsto 公网映射：家里、外面都能连（证书可信，仅 https；http 打不通）。
// 在家想更快可在设置页改内网直连 http://192.168.31.198:18190
export const DEFAULT_SERVER = 'https://dsm920-ddsnto-trilium-notes.x.ddnsto.com';

// 速记落点：默认放在根下的「收件箱」；不存在时自动创建
export const DEFAULT_INBOX_TITLE = '收件箱';

// 本地缓存条数上限
export const CACHE_LIMIT = 200;
