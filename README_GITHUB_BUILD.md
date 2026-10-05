# GitHub 编译说明

这个目录已经补齐 GitHub Actions 配置。

## 上传到仓库根目录

至少需要这些文件：

- `V16RequestConstructionTrace.m`
- `V16RequestConstructionTrace.plist`
- `Makefile`
- `control`
- `.github/workflows/build-v16-request-trace.yml`

如果你原来的 `dylib` 仓库已经有其它版本，也可以把这些文件直接放到仓库根目录。

## GitHub 网页上传

1. 打开你的 GitHub 仓库。
2. `Add file` -> `Upload files`。
3. 把本压缩包解压后的目录内容拖进去。
4. 注意 `.github/workflows/build-v16-request-trace.yml` 必须保持这个目录结构。
5. Commit changes。
6. 打开仓库顶部 `Actions`。
7. 选择 `Build V16 Request Construction Trace`。
8. 点 `Run workflow`。
9. 编译结束后，在该次运行页面底部下载：
   `V16RequestConstructionTrace-deb`

## 如果仓库已有同名 Makefile

不要直接覆盖旧项目的 Makefile。
更稳妥的方式是把这个版本放进单独子目录，例如：

`V16RequestConstructionTrace/`

但如果放在子目录，workflow 的 build 步骤需要改成：

`cd V16RequestConstructionTrace && make package FINALPACKAGE=1`

当前这个包默认按照“文件放在仓库根目录”配置。
