#!/bin/sh
set -u
exit 0

# missing-label |
defaults write NSGlobalDomain A -int 1

# bad id here | id 含空格
defaults write NSGlobalDomain B -int 1

# dup-id | 第一项
defaults write NSGlobalDomain C -int 1

# dup-id | 重复 id
defaults write NSGlobalDomain D -int 1

# empty-body | 只有头没有命令

# next-ok | 下一项
defaults write NSGlobalDomain E -int 1

# almost: colon | 用了冒号而不是竖线
defaults write NSGlobalDomain F -int 1
