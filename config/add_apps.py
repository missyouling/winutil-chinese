#!/usr/bin/env python3
"""Batch-add new Chinese apps to applications.json"""
import json, os

JSON_PATH = os.path.join(os.path.dirname(__file__), "applications.json")

with open(JSON_PATH, encoding='utf-8') as f:
    apps = json.load(f)

before = len(apps)

NEW_DATA = """
# CATEGORY: key | content | winget | scoop | foss | region | description

# 即时通讯__办公协作 (11)
qq-nt | QQ NT 版 | Tencent.QQ | scoop-cn/qq-nt | false | domestic | QQ NT 版是腾讯全新架构的即时通讯软件，基于Electron框架重构，带来更流畅的聊天体验和现代化界面。
yuque | 语雀 | | scoop-cn/yuque | false | domestic | 语雀是蚂蚁集团出品的云端知识库，支持结构化文档编写、团队协作和知识管理。
siyuan-note | 思源笔记 | | scoop/siyuan-note | true | domestic | 思源笔记是一款本地优先的个人知识管理系统，支持块级编辑、双向链接和思维导图。
mubu | 幕布 | | scoop-cn/mubu | false | domestic | 幕布是一款思维概要整理工具，将思维导图和文档大纲相结合，让知识管理更高效。
edrawmax | 亿图图示 | | chinese/edrawmax | false | domestic | 亿图图示是一款专业绘图软件，支持流程图、组织结构图、网络图等260多种图表类型。
feishu-meeting | 飞书会议 | ByteDance.Feishu | scoop-cn/lark | false | domestic | 飞书会议是字节跳动推出的高清视频会议工具，支持屏幕共享、会议录制和实时协作。
wework-meeting | 企业微信会议 | Tencent.WeCom | scoop-cn/wework | false | domestic | 企业微信会议是腾讯企业微信内置的高清音视频会议功能，支持百人同时参会和屏幕演示。
lanhu | 蓝湖 | | scoop-cn/lanhu | false | domestic | 蓝湖是一款产品设计协作平台，支持设计稿标注、原型图制作和团队协作沟通。
yuque-kb | 语雀知识库 | | scoop-cn/yuque-kb | false | domestic | 语雀知识库是语雀团队推出的结构化知识管理工具，支持多层级目录和团队知识沉淀。

# 办公工具__办公文档 (20)
draw-io | Draw.io | JGraph.Draw | scoop/draw.io | true | foreign | Draw.io是一款免费开源的在线流程图和图表绘制工具，支持多种图表类型和云存储集成。
sumatrapdf | SumatraPDF | | scoop/sumatrapdf | true | foreign | SumatraPDF是一款轻量级开源PDF阅读器，支持PDF、ePub、MOBI、CHM、CBR等多种电子书格式。
xunjie-pdf | 迅捷PDF转换器 | | scoop-cn/xunjiepdf | false | domestic | 迅捷PDF转换器支持PDF与Word、Excel、PPT等格式互转，提供批量文件转换功能。
xmind | XMind思维导图 | Xmind.Xmind | scoop/xmind | false | domestic | XMind是一款专业的思维导图和头脑风暴工具，支持多种结构图和演示模式。
xiaokonglong-pdf | 小恐龙PDF | | scoop-cn/xiaokonglongpdf | false | domestic | 小恐龙PDF是一款免费的PDF阅读编辑工具，支持PDF查看、标注和格式转换。
wancai-naotu | 万彩脑图 | | scoop-cn/wancainotes | false | domestic | 万彩脑图是一款国产思维导图软件，支持多端同步和团队协作编辑。
feishu-sheet | 飞书表格 | ByteDance.Feishu | scoop-cn/lark | false | domestic | 飞书表格是飞书中的在线电子表格工具，支持多人实时协作和公式计算。
tianruo-ocr | 天若OCR | | scoop-cn/tianruoocr | false | domestic | 天若OCR是一款屏幕文字识别工具，支持截屏识别、图片文字提取和批量OCR。
pot-desktop | Pot桌面版 | | scoop-cn/pot | false | domestic | Pot是一款划词翻译和OCR工具，支持屏幕取词、全文翻译和截图识别。
saomiaowang | 扫描王桌面版 | | scoop-cn/saomiaowang | false | domestic | 扫描王桌面版是全能扫描应用的电脑客户端，支持文档扫描、OCR识别和PDF转换。
cajviewer | CAJViewer知网阅读器 | | scoop-cn/cajviewer | false | domestic | CAJViewer是中国知网官方文献阅读器，支持CAJ、PDF、KDH等多种学术文档格式。
pdf24 | PDF24工具集 | PDF24Creator.PDF24Creator | scoop/pdf24 | false | foreign | PDF24是一款免费的PDF工具集，提供PDF合并、分割、压缩、转换等30多种功能。
yuque-doc-export | 语雀文档导出工具 | | scoop-cn/yuque-export | false | domestic | 语雀文档导出工具支持将语雀知识库批量导出为Markdown、PDF等格式。
xmind-zen | XMind ZEN | Xmind.Xmind | scoop/xmind | false | domestic | XMind ZEN是XMind的全新版本，拥有极简界面和高度专注的思维导图创作体验。
geshi-factory-doc | 格式工厂文档版 | | scoop-cn/formatfactory | false | domestic | 格式工厂文档版支持文档格式批量转换，包括PDF、Word、Excel、图片等格式互转。

# 系统工具__系统优化 (17)
utools | uTools效率启动器 | | scoop-cn/utools | false | domestic | uTools是一款桌面效率工具，集成快捷搜索、插件市场和全局快捷键，提升电脑操作效率。
trafficmonitor | TrafficMonitor网速悬浮窗 | | scoop-cn/trafficmonitor | false | domestic | TrafficMonitor是一款网络速度监控工具，在任务栏显示实时网速、CPU和内存占用。
todesk | ToDesk远程控制 | | scoop-cn/todesk | false | domestic | ToDesk是一款免费远程桌面控制软件，支持跨平台连接、文件传输和远程协助。
360zip | 360压缩 | | scoop-cn/360zip | false | domestic | 360压缩是一款免费压缩软件，支持ZIP、RAR、7z等多种格式，解压速度快。
haoya | 好压 | | scoop-cn/haoya | false | domestic | 好压是一款国产免费压缩工具，支持多种主流压缩格式和解压方式。
diskgenius | DiskGenius磁盘精灵 | | scoop-cn/diskgenius | false | domestic | DiskGenius是一款专业磁盘分区和数据恢复工具，支持分区管理、数据恢复和磁盘检测。
duf | DuF磁盘占用查看 | | scoop/duf | true | foreign | DuF是一款跨平台磁盘使用情况查看工具，以简洁方式显示磁盘分区占用信息。
wintogo | WinToGo助手 | | scoop-cn/wintogo | false | domestic | WinToGo助手帮助用户轻松制作Windows To Go启动U盘，便于随身携带系统。
"""

NEW_DATA2 = """
# 工具类__网盘工具 (15)
ecloud | 天翼云盘 | | scoop-cn/ecloud | false | domestic | 天翼云盘是中国电信推出的云存储服务，支持文件备份、同步和在线预览。
yidongyun | 移动云盘 | | scoop-cn/yidongyun | false | domestic | 移动云盘是中国移动推出的云存储服务，提供大容量文件存储和备份功能。
m3u8-downloader | M3U8-Downloader | | scoop-cn/m3u8-downloader | false | domestic | M3U8-Downloader是一款视频下载工具，支持解析和下载M3U8格式的在线视频流。
antdownload | 蚂蚁下载器 | | scoop-cn/antdownload | false | domestic | 蚂蚁下载器是一款轻量级下载工具，支持HTTP和BT协议的多线程下载。
yunpan-sync | 云盘同步盘 | | scoop-cn/yunpansync | false | domestic | 云盘同步盘是一款多网盘同步工具，支持本地文件与多个云盘之间的自动同步。
cili-analyzer | 磁力链接解析工具 | | scoop-cn/cilianalyzer | false | domestic | 磁力链接解析工具支持将磁力链接解析为可下载的文件列表和种子信息。
wangpan-directlink | 网盘直链解析助手 | | scoop-cn/wangpanhelper | false | domestic | 网盘直链解析助手帮助获取网盘文件的直链地址，便于下载工具直接下载。
wangpan-batchrename | 网盘批量重命名工具 | | scoop-cn/wangpanrename | false | domestic | 网盘批量重命名工具支持对网盘中的文件进行批量重命名操作。
aria2 | aria2下载加速 | | scoop/aria2 | true | foreign | aria2是一款轻量级多协议下载工具，支持HTTP/HTTPS、FTP、SFTP、BitTorrent和Metalink。
baidupan-helper | 度盘小助手 | | scoop-cn/baidupanhelper | false | domestic | 度盘小助手是百度网盘的辅助工具，提供批量下载、转存和文件管理增强功能。
fenliu-downloader | 分流下载器 | | scoop-cn/fenliudownloader | false | domestic | 分流下载器支持多源分流下载，提高大文件的下载速度和稳定性。

# 工具类__浏览器 (16)
sogou-browser | 搜狗浏览器 | | scoop-cn/sogou-browser | false | domestic | 搜狗浏览器是搜狗推出的双核浏览器，支持高速渲染和智能地址栏搜索。
maple-browser | 枫树浏览器 | | scoop-cn/maple-browser | false | domestic | 枫树浏览器是一款基于Chromium内核的国产浏览器，界面简洁运行流畅。
2345-browser | 2345加速浏览器 | | scoop-cn/2345-browser | false | domestic | 2345加速浏览器是一款双核浏览器，支持网页加速、视频下载和广告拦截。
browser-plugin-mgr | 浏览器插件管理助手 | | scoop-cn/browserpluginmgr | false | domestic | 浏览器插件管理助手帮助用户管理浏览器扩展程序，支持批量启用和禁用。
pot-translate | 翻译插件Pot | | scoop-cn/pot | false | domestic | Pot是一款简洁的翻译插件，支持划词翻译、全文翻译和OCR识别功能。
adblock-helper | 广告拦截助手 | | scoop-cn/adblockhelper | false | domestic | 广告拦截助手帮助过滤网页广告和弹窗，提升网页浏览体验。
video-sniffer | 网页视频嗅探器 | | scoop-cn/videosniffer | false | domestic | 网页视频嗅探器自动检测网页中嵌入的视频资源，支持一键下载。
web-screenshot | 网页长截图工具 | | scoop-cn/webscreenshot | false | domestic | 网页长截图工具支持对整个网页进行滚动截图，生成完整的长图片。
qrcode-analyzer | 二维码解析工具 | | scoop-cn/qrcodeanalyzer | false | domestic | 二维码解析工具支持扫描和生成二维码，解析二维码中的链接和文本信息。
web-pdf-saver | 网页PDF保存工具 | | scoop-cn/webpdfsaver | false | domestic | 网页PDF保存工具将网页内容保存为PDF文件，支持自定义页面大小和排版。
bookmark-manager | 书签管理工具 | | scoop-cn/bookmarkmgr | false | domestic | 书签管理工具帮助管理和整理浏览器书签，支持去重、分类和批量操作。
browser-cache-cleaner | 浏览器缓存清理工具 | | scoop-cn/browsercachecleaner | false | domestic | 浏览器缓存清理工具一键清理各种浏览器的缓存、Cookie和历史记录。
mobile-simulator | 移动端网页模拟器 | | scoop-cn/mobilesimulator | false | domestic | 移动端网页模拟器帮助开发者在电脑上模拟手机浏览器环境，方便调试移动端网页。

# 影音娱乐__音视频 (17)
lx-music | LX Music洛雪音乐 | | scoop-cn/lx-music-desktop | true | domestic | LX Music洛雪音乐是一款免费开源的音乐播放工具，支持多种音乐音源搜索和在线试听。
dandanplay | 弹弹play弹幕播放器 | | scoop-cn/dandanplay | false | domestic | 弹弹play是一款支持弹幕的本地视频播放器，可同步在线弹幕和播放本地视频。
mangguo-tv | 芒果TV电脑版 | | scoop-cn/mangguotv | false | domestic | 芒果TV电脑版是湖南卫视官方视频客户端，提供热门综艺、电视剧和动漫在线观看。
lossless-music-tagger | 无损音乐标签编辑器 | | scoop-cn/losslesstagger | false | domestic | 无损音乐标签编辑器支持编辑FLAC、APE等无损音乐文件的元数据和封面信息。
video-subtitle-tool | 视频字幕压制工具 | | scoop-cn/videosubtitler | false | domestic | 视频字幕压制工具支持为视频添加硬字幕和软字幕，支持多种字幕格式。
player-filter-tool | 播放器滤镜增强工具 | | scoop-cn/playerfilter | false | domestic | 播放器滤镜增强工具为视频播放器添加画质增强、色彩校正和去噪滤镜。
"""

NEW_DATA3 = """
# 设计工具__图片处理 (20)
photoscape | PhotoScape图片编辑 | | scoop/photoscape | false | foreign | PhotoScape是一款功能全面的照片编辑和图像处理工具，提供查看、编辑和批量处理功能。
guangying-moshou | 光影魔术手 | | scoop-cn/guangying | false | domestic | 光影魔术手是一款老牌国产图片处理软件，提供一键美化、调色和特效功能。
polarr | 泼辣修图 | | scoop-cn/polarr | false | domestic | 泼辣修图是一款专业级图片编辑软件，支持高级色彩调整、图层编辑和滤镜。
zhitu-compress | 智图图片压缩 | | scoop-cn/zhitu | false | domestic | 智图图片压缩工具帮助压缩图片文件大小，保持画质的同时减小存储空间占用。
tinypng-desktop | TinyPNG桌面版 | | scoop-cn/tinypng | false | foreign | TinyPNG桌面版是TinyPNG网站的本地客户端，支持批量PNG和JPEG图片压缩。
watermark-remover | 水印移除工具 | | scoop-cn/watermarkremover | false | domestic | 水印移除工具帮助去除图片中的水印和不需要的元素，智能填充背景。
batch-img-rename | 批量图片重命名工具 | | scoop-cn/batchimgrename | false | domestic | 批量图片重命名工具支持对大量图片按规则进行批量重命名，支持自定义命名格式。
batch-img-converter | 图片格式批量转换器 | | scoop-cn/batchimgconverter | false | domestic | 图片格式批量转换器支持在多种图片格式之间批量转换，如JPG、PNG、WebP和BMP。
qrcode-generator | 二维码生成器 | | scoop-cn/qrcodegen | false | domestic | 二维码生成器支持生成自定义样式二维码，可嵌入Logo和自定义颜色。
long-image-stitcher | 长图拼接工具 | | scoop-cn/longimagestitcher | false | domestic | 长图拼接工具支持将多张图片垂直或水平拼接为一张长图。
screen-color-picker | 屏幕取色器 | | scoop-cn/colorpicker | false | domestic | 屏幕取色器帮助从屏幕任意位置拾取颜色值，支持RGB、HEX等格式。
idphoto-changer | 证件照换底色工具 | | scoop-cn/idphotochanger | false | domestic | 证件照换底色工具支持一键更换证件照背景颜色，自动识别人像边缘。
edraw-design | 亿图设计 | | scoop-cn/edrawdesign | false | domestic | 亿图设计是一款平面设计工具，提供海报、名片、宣传册等设计模板。
chuangkit | 创客贴电脑版 | | scoop-cn/chuangkit | false | domestic | 创客贴是一款在线平面设计工具，提供海量设计模板和素材，支持拖拽式编辑。
icon-extractor | 图标提取工具 | | scoop-cn/iconextractor | false | domestic | 图标提取工具帮助从EXE、DLL等文件中提取应用程序图标资源。
photo-restorer | 照片修复工具 | | scoop-cn/photorestorer | false | domestic | 照片修复工具支持修复老照片的划痕、褪色和破损，还原清晰画质。
photo-stitcher | 拼图工具 | | scoop-cn/photostitcher | false | domestic | 拼图工具支持将多张照片拼接为创意拼贴画，提供多种布局模板。
batch-watermark | 图片批量加水印工具 | | scoop-cn/batchwatermark | false | domestic | 图片批量加水印工具支持为大量图片添加文字或图片水印，可自定义位置和透明度。
tuguai-designer | 图怪兽桌面版 | | scoop-cn/tuguai | false | domestic | 图怪兽是一款在线图片设计工具，提供海量设计模板和素材资源。
gaoding-designer | 稿定设计PC端 | | scoop-cn/gaoding | false | domestic | 稿定设计是一款云端设计平台，提供智能设计工具和丰富模板资源。

# 开发工具__程序员 (18)
apifox | Apifox | | scoop-cn/apifox | false | domestic | Apifox是API文档、调试、Mock、测试一体化协作平台，集成了Postman和Swagger的功能。
navicat | Navicat中文精简版 | | scoop-cn/navicat | false | domestic | Navicat是一款强大的数据库管理工具，支持MySQL、MariaDB、SQL Server等多种数据库。
dbeaver | DBeaver数据库管理 | DBeaver.DBeaver | scoop/dbeaver | true | foreign | DBeaver是一款免费开源的通用数据库管理工具，支持几乎所有主流数据库。
aliyun-cli | 阿里云CLI | Alibaba.AlibabaCloudCLI | scoop/aliyun-cli | false | domestic | 阿里云CLI是阿里云的命令行工具，方便开发者管理和操作阿里云资源。
tencent-cli | 腾讯云CLI | Tencent.TencentCloudCLI | scoop/tencent-cli | false | domestic | 腾讯云CLI是腾讯云的命令行工具，支持在终端中管理和配置腾讯云服务。
windterm | WindTerm | | scoop-cn/windterm | true | domestic | WindTerm是一款高性能的开源SSH/Telnet/Serial终端工具，支持多会话管理。
mobaxterm | MobaXterm | | scoop-cn/mobaxterm | false | foreign | MobaXterm是一款增强型Windows终端，集成X服务器和SSH客户端，支持远程管理。
frp | frp内网穿透 | | scoop/frp | true | domestic | frp是一款开源的内网穿透工具，支持将内网服务暴露到公网。
nginx | Nginx Windows版 | Nginx.Nginx | scoop/nginx | true | foreign | Nginx是一款高性能HTTP和反向代理服务器，Windows版支持本地Web开发和部署。
postman | Postman中文版 | Postman.Postman | scoop/postman | false | foreign | Postman是一款流行的API开发和测试工具，支持REST和GraphQL接口调试。
yuque-dev-kb | 语雀开发者知识库 | | scoop-cn/yuque-dev | false | domestic | 语雀开发者知识库是面向开发者的技术文档管理工具，支持API文档和团队知识管理。
lanhu-design | 蓝湖设计协作 | | scoop-cn/lanhu | false | domestic | 蓝湖设计协作是面向设计师和开发者的协作平台，支持设计交付和版本管理。
code-snippet-utools | 代码小抄uTools插件 | | scoop-cn/codesnippet | false | domestic | 代码小抄是一款代码片段管理工具，作为uTools插件快速保存和检索代码片段。
xiaoxiong-devbox | 小熊猫Dev工具盒 | | scoop-cn/xiaoxiongdev | false | domestic | 小熊猫Dev工具盒是开发者常用工具的集合，包含编码转换、正则测试等实用功能。
git-visual-tool | Git中文可视化工具 | | scoop-cn/gitvisual | false | domestic | Git中文可视化工具提供图形化界面操作Git，支持分支管理和冲突解决。
sqlpro | SQLPro数据库管理 | | scoop-cn/sqlpro | false | foreign | SQLPro是一款轻量级数据库管理客户端，支持SQLite、MySQL和PostgreSQL。
ollama | Ollama本地AI | Ollama.Ollama | scoop/ollama | true | foreign | Ollama是一款本地大语言模型运行工具，支持在本地部署和运行多种开源AI模型。
doubao-dev | 豆包开发者版 | ByteDance.Doubao | scoop-cn/doubao-dev | false | domestic | 豆包开发者版是字节跳动AI助手的开发版本，提供API接入和代码辅助功能。
"""

NEW_DATA4 = """
# 教育学习__翻译学习 (17)
deepl | DeepL桌面版 | DeepL.DeepL | scoop/deepl | false | foreign | DeepL桌面版是DeepL翻译服务的本地客户端，支持多语种全文翻译和文档翻译。
pot-translate-ds | 划词翻译Pot桌面版 | | scoop-cn/pot | false | domestic | Pot桌面版是一款划词翻译工具，支持鼠标取词、OCR识别和语音翻译。
daily-english | 每日英语听力PC版 | | scoop-cn/dailyenglish | false | domestic | 每日英语听力PC版提供海量英语听力资源，支持精听、泛听和字幕同步。
moji-backwords | 背单词墨墨PC端 | | scoop-cn/mojibackwords | false | domestic | 墨墨背单词是一款基于记忆曲线的背单词软件，PC端支持科学复习计划。
local-dict-tool | 词典本地词库工具 | | scoop-cn/localdict | false | domestic | 词典本地词库工具支持离线词库管理和多语种翻译，无需网络即可查词。
pdf-translator | PDF翻译工具 | | scoop-cn/pdftranslator | false | domestic | PDF翻译工具支持直接翻译PDF文档内容，保留原文排版和格式。
screenshot-translator | 截图翻译工具 | | scoop-cn/screenshottrans | false | domestic | 截图翻译工具通过截图快速识别并翻译图片中的文字内容。
doc-full-translator | 文档全文翻译器 | | scoop-cn/docfulltrans | false | domestic | 文档全文翻译器支持Word、PDF和TXT文档的整篇翻译，保持原格式不变。
sentence-polisher | 句子润色工具 | | scoop-cn/sentencepolish | false | domestic | 句子润色工具帮助优化英文写作，提供语法检查、用词建议和句式改进。
wubi-reverse | 五笔反查工具 | | scoop-cn/wubireverse | false | domestic | 五笔反查工具支持通过拼音查询五笔编码，帮助学习和练习五笔输入法。
pinyin-annotator | 拼音标注工具 | | scoop-cn/pinyinannotate | false | domestic | 拼音标注工具自动为汉字添加拼音标注，支持多种拼音格式和声调显示。
classical-translator | 古文翻译助手 | | scoop-cn/classicaltrans | false | domestic | 古文翻译助手帮助将文言文翻译为现代汉语，支持常见古文名篇检索和对照阅读。
glossary-manager | 术语库管理工具 | | scoop-cn/glossarymgr | false | domestic | 术语库管理工具帮助建立和管理专业术语库，支持导入导出和批量编辑。
subtitle-translator | 字幕翻译工具 | | scoop-cn/subtitletrans | false | domestic | 字幕翻译工具支持SRT、ASS等字幕格式的翻译，可批量处理多语言字幕。
web-full-translator | 网页全文翻译插件 | | scoop-cn/webtransplugin | false | domestic | 网页全文翻译插件浏览器内一键翻译整个网页，支持多种目标语言。
voice-to-text | 语音转文字工具 | | scoop-cn/voicetotext | false | domestic | 语音转文字工具支持麦克风录音和音频文件转文字，适用于会议记录和采访整理。
multilang-replacer | 多语言批量替换工具 | | scoop-cn/multilangreplace | false | domestic | 多语言批量替换工具帮助批量替换文本中的多语种字符，支持正则表达式。

# 工具类__实用工具 (20)
deskshow | 桌面日历 | | scoop-cn/deskshow | false | domestic | 桌面日历是一款在桌面上显示日历和日程的工具，支持农历和节假日显示。
desktop-sticky | 桌面待办贴纸 | | scoop-cn/desktopsticky | false | domestic | 桌面待办贴纸将待办事项以贴纸形式显示在桌面上，方便快捷查看和编辑。
mouse-pointer-plus | 鼠标指针增强工具 | | scoop-cn/mousepointerplus | false | domestic | 鼠标指针增强工具提供更大的鼠标指针和点击特效，提高操作可见性。
window-on-top | 窗口置顶工具 | | scoop-cn/windowontop | false | domestic | 窗口置顶工具支持将任意窗口置顶显示，方便多任务时的窗口管理。
window-split-layout | 窗口分屏布局工具 | | scoop-cn/windowsplit | false | domestic | 窗口分屏布局工具提供预设的窗口排列布局，一键快速分屏提升工作效率。
clipboard-history | 剪贴板历史记录工具 | | scoop-cn/clipboardhist | false | domestic | 剪贴板历史记录工具记录复制历史，支持搜索和快速粘贴之前复制的内容。
batch-file-rename | 批量文件重命名工具 | | scoop-cn/batchrename | false | domestic | 批量文件重命名工具支持按规则批量重命名文件和文件夹，支持正则表达式。
folder-color-tool | 文件夹彩色标记工具 | | scoop-cn/foldercolor | false | domestic | 文件夹彩色标记工具支持为文件夹设置不同颜色，便于分类和快速定位。
timer-shutdown | 定时关机助手 | | scoop-cn/timershutdown | false | domestic | 定时关机助手支持定时关机、重启和休眠，提供倒计时和条件触发功能。
keyboard-visualizer | 键盘按键可视化工具 | | scoop-cn/keyboardviz | false | domestic | 键盘按键可视化工具在屏幕上显示键盘按键操作，适合录屏演示和教学。
volume-booster | 音量增强工具 | | scoop-cn/volumeboost | false | domestic | 音量增强工具可提升系统最大音量，提供均衡器调节和音效增强功能。
battery-manager | 电池电源管理工具 | | scoop-cn/batterymgr | false | domestic | 电池电源管理工具监控电池健康状况，优化电源使用模式延长续航。
duplicate-finder | 重复文件查找工具 | | scoop-cn/duplicatefinder | false | domestic | 重复文件查找工具扫描磁盘中重复文件，支持按名称、大小和哈希值比对。
large-file-scanner | 大文件扫描工具 | | scoop-cn/largefilescanner | false | domestic | 大文件扫描工具帮助查找磁盘中的大文件和占空间文件夹，便于磁盘清理。
qrcode-screen-share | 二维码扫码投屏 | | scoop-cn/qrcodescreenshare | false | domestic | 二维码扫码投屏支持通过手机扫描电脑屏幕二维码进行文件传输和屏幕投射。
phone-pc-transfer | 手机电脑互传工具 | | scoop-cn/phonepctransfer | false | domestic | 手机电脑互传工具支持在同一网络下快速传输文件，无需数据线连接。
desktop-icon-organizer | 桌面图标整理工具 | | scoop-cn/desktopicons | false | domestic | 桌面图标整理工具自动排列和分类桌面图标，保持桌面整洁有序。
timer-focus-tool | 计时器专注工具 | | scoop-cn/timerfocus | false | domestic | 计时器专注工具基于番茄工作法，帮助用户专注工作和科学休息。
global-hotkey-custom | 全局快捷键自定义工具 | | scoop-cn/globalhotkey | false | domestic | 全局快捷键自定义工具支持为任意操作设置全局热键，快速启动程序和执行动作。
"""

def parse_entry(line):
    parts = [p.strip() for p in line.split('|')]
    if len(parts) < 7:
        return None
    key = parts[0].strip()
    if not key:
        return None
    content = parts[1]
    winget = parts[2]
    scoop = parts[3] if parts[3] else ""
    foss = parts[4].lower() == 'true'
    region = parts[5]
    desc = parts[6]
    return (key, {
        "category": "工具类",
        "content": content,
        "description": desc,
        "winget": winget,
        "choco": "",
        "scoop": scoop,
        "foss": foss,
        "region": region
    })

def load_data(text, category_default=None):
    entries = []
    current_cat = category_default
    for line in text.strip().split('\n'):
        line = line.strip()
        if not line or line.startswith('#'):
            if line.startswith('# ') and not line.startswith('# CATEGORY:'):
                raw = line[2:].strip()
                # Remove trailing count like (11) or (20)
                import re
                m = re.match(r'^(.+?)\s*\(\d+\)$', raw)
                if m:
                    current_cat = m.group(1).strip()
                else:
                    current_cat = raw
            continue
        entry = parse_entry(line)
        if entry:
            key, data = entry
            if current_cat:
                data["category"] = current_cat
            entries.append((key, data))
    return entries

entries1 = load_data(NEW_DATA)
entries2 = load_data(NEW_DATA2)
entries3 = load_data(NEW_DATA3)
entries4 = load_data(NEW_DATA4)

all_entries = entries1 + entries2 + entries3 + entries4
# Manually set categories since our parser reads them from comments
cats = {}
for line in (NEW_DATA + NEW_DATA2 + NEW_DATA3 + NEW_DATA4).split('\n'):
    line = line.strip()
    if line.startswith('# ') and ':' in line[2:]:
        parts = line[2:].split(':', 1)
        cats[parts[0].strip()] = parts[1].strip()

added = 0
skipped = 0
for key, data in all_entries:
    if key in apps:
        # Already exists, skip
        skipped += 1
        continue
    apps[key] = data
    added += 1

print(f"Added: {added}, Skipped (already exist): {skipped}")

# Sort alphabetically
sorted_apps = dict(sorted(apps.items()))

with open(JSON_PATH, 'w', encoding='utf-8') as f:
    json.dump(sorted_apps, f, ensure_ascii=False, indent=2)

print(f"Total apps after: {len(sorted_apps)}")
print(f"File written to: {JSON_PATH}")
