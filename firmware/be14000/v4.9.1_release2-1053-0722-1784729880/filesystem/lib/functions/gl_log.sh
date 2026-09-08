#!/bin/sh

# 默认日志级别为 INFO
LOG_LEVEL="INFO"

# 设置日志级别的函数
set_log_level() {
    LEVEL=$1
    if [ "$LEVEL" = "DEBUG" ] || [ "$LEVEL" = "INFO" ] || [ "$LEVEL" = "ERROR" ]; then
        LOG_LEVEL=$LEVEL
    else
        echo "Invalid log level: $LEVEL. Using default level: DEBUG"
        LOG_LEVEL="DEBUG"
    fi
}

# 获取当前日志级别的数字值
get_log_level_value() {
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
        return 0
    elif [ "$LOG_LEVEL" = "INFO" ]; then
        return 1
    elif [ "$LOG_LEVEL" = "ERROR" ]; then
        return 2
    fi
}

# 获取调用者信息（脚本名和行号）
get_caller_info() {
    # 使用 $0 获取当前脚本名
    script_name=$(basename "$0")
    # 传递的行号
    line_num=$1

    echo "($script_name:$line_num)"
}

# 记录日志消息
log_message() {
    LEVEL=$1
    LINE_NO=$2
    MODULE=$3
    MESSAGE=$4

    # 获取当前日志级别的数字值
    get_log_level_value
    CURRENT_LEVEL=$?

    # 获取调用者的脚本名和行号
    caller_info=$(get_caller_info "$LINE_NO")

    # 判断当前日志级别是否允许输出当前消息
    if [ "$LEVEL" = "DEBUG" ]; then
        if [ $CURRENT_LEVEL -le 0 ]; then
            #echo "$caller_info DEBUG: $MESSAGE"
            logger -p debug -t $MODULE "$caller_info $MESSAGE"
        fi
    elif [ "$LEVEL" = "INFO" ]; then
        if [ $CURRENT_LEVEL -le 1 ]; then
            #echo "$caller_info INFO: $MESSAGE"
            logger -p info  -t $MODULE "$caller_info $MESSAGE"
        fi
    elif [ "$LEVEL" = "ERROR" ]; then
        #echo "$caller_info ERROR: $MESSAGE"
        logger -p error  -t $MODULE "$caller_info $MESSAGE"
    else
        echo "Invalid log level: $LEVEL"
    fi
}

# 记录 debug 级别的日志
log_debug() {
    log_message "DEBUG" "$1" "$2" "$3"
}

# 记录 info 级别的日志
log_info() {
    log_message "INFO" "$1" "$2" "$3"
}

# 记录 error 级别的日志
log_error() {
    log_message "ERROR" "$1" "$2" "$3"
}
