# AI Arena

一个给自己用的多 AI 辩论工作台。输入一个拿不准的问题，选择已经在用的网页版 AI，让它们先独立作答，再交换质疑。最后得到一份可以直接用于判断的回答，并能查看哪条意见改变了结论、哪些问题仍有争议。

## 项目文档

- **先看自用版**　[产品需求与质量验收](docs/product-design.md) · [技术方案与开发顺序](docs/technical-design.md)。从一次实际判断出发，说明如何自动互评、保存原文、识别分歧并交付结论。
- **核对参照版**　[两库源码分析](docs/reference-review.md) · [Arena 的 33 项功能](docs/arena-features.md) · [Panelize 的 23 项功能](docs/panelize-features.md)。逐项列出原有行为、参照版复核、自用版取舍和验证方法。
- **检查遗漏与兼容性**　[源码覆盖对账](docs/source-coverage.md) · [14 个站点的验证表](docs/provider-validation.md)。可从源码入口反查需求，再按站点登记真实浏览器结果。

2026-11-21 完成首轮设计。建议采用 Chrome 扩展、独立工作台和原生网页标签。当前交付为设计文档，网页兼容性等待实测。
