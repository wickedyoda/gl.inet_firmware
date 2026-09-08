#!/bin/sh

use_fw4='0'
[ -n "$(which fw4)" ] && use_fw4='1'

FW4_FILE_PATH=''
FW4_TABLE_NAME=''
FW4_CHAINS_SET=''
FW4_APPEND_STATEMENTS=''

# Directly add content to the table. Currently equivalent to directly executing the nft command.
fw4_add_member_directly() {
    local table_name="$1"
    local member_type="$2"
    local content="$3"
    nft add ${member_type} ${table_name} ${content}
}

fw4_insert_rule_directly() {
    local table_name="$1"
    local content="$2"
    local index="$3"
    nft insert rule ${table_name}"${index:+ $index}" ${content}
}

fw4_set_create_member_of_table() {
    local member_type="$1"
    local member_name="$2"
    local content="$3"
    echo -e "\n\t${member_type} ${member_name} {\n\t\t${content}\n\t}" >> $FW4_FILE_PATH
}

fw4_set_add_rule_to_chain() {
    fw4_set_create_member_of_table "chain" "$1" "$2"
}

fw4_set_query_chain_exists() {
    local chain_name="$1"
    for name in $FW4_CHAINS_SET ;do
	[ "$name" = "$chain_name" ] && return 1
    done
    return 0
}

fw4_set_create_chain() {
    fw4_set_add_rule_to_chain "$1" "$2"
    FW4_CHAINS_SET="${FW4_CHAINS_SET} $1"
}

# Calling this function can add content after the table is created and the initial content is written. It is usually used for insert operations.
fw4_set_add_append_statement() {
    local content=$1
    FW4_APPEND_STATEMENTS="${FW4_APPEND_STATEMENTS}
${content};"
}

# Add instructions to the file. This is usually used in hot-plug scenarios to persist firewall changes made during event handling, so that the modifications will not be lost when the service is reloaded next time.
fw4_set_add_statement_to_file() {
    local file_path="$1";shift
    local content="$1";shift

    touch "${file_path}" >/dev/null 2>&1
    [ "$?" != '0' ] && return 2

    echo -e "${content}" >> ${file_path}
    return 0
}

# Undoes persistent changes made by fw4_set_add_hotplug_statement
fw4_set_delete_statement_from_file() {
    local file_path="$1";shift
    local content="$1";shift

    touch "${file_path}" >/dev/null 2>&1
    [ "$?" != '0' ] && return 2

    [ -n "${content}" ] && sed -i "/${content}/d" ${file_path}
    return 0
}

fw4_init_set_context() {
    local file_path="$1";shift
    local table_name="$1";shift

    [ -z "${file_path}" -o -z "${table_name}" ] && return 1

    touch "${file_path}" >/dev/null 2>&1
    [ "$?" != '0' ] && return 2

    FW4_TABLE_NAME="${table_name}"
    FW4_FILE_PATH="${file_path}"
    FW4_CHAINS_SET=''
    FW4_APPEND_STATEMENTS=''
    echo -e "table $FW4_TABLE_NAME {" > $FW4_FILE_PATH

    return 0
}

fw4_set_finish_and_apply() {
    echo -e "\n}" >> $FW4_FILE_PATH
    echo -e "$FW4_APPEND_STATEMENTS" >> $FW4_FILE_PATH
    nft delete table $FW4_TABLE_NAME
    nft -f $FW4_FILE_PATH
}

