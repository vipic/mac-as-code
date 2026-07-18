#!/bin/sh
set -u
exit 0

# sample-int | 示例整数设置
defaults write NSGlobalDomain ExampleKey -int 1

# sample-multi | 多行命令项
defaults write com.example.app Foo -int 1
defaults write com.example.app Bar -string baz

# sample-with-comment | 项内可有普通注释
# 这是普通注释，不算新项
defaults write -g ExampleFlag -bool true
