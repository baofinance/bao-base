#!/usr/bin/env bats

setup() {
    source "bin-modules/logging"
    logging_config debug
    source "script/deploying"
}

@test "_deploying_convert_args_to_yaml function handles YAML" {
    run _deploying_convert_args_to_yaml "hello:world"
    [ "$status" -eq 0 ]
    [ "$output" == "hello: world" ]

    run _deploying_convert_args_to_yaml '
    hello:world
    old: man
    young:  "boy or baby"'
    [ "$status" -eq 0 ]
    expected=$(cat <<EOF
hello: world
old: man
young: "boy or baby"
EOF
    )
    echo "---output---"
    echo "$output"
    echo "---expected---"
    echo "$expected"
    echo "------"
    [ "$output" == "$expected" ]
}

@test "_deploying_convert_args_to_yaml function handles long form switches" {
    run _deploying_convert_args_to_yaml --hello world
    [ "$status" -eq 0 ]
    [ "$output" == "hello: world" ]

    run _deploying_convert_args_to_yaml --hello="world"
    [ "$status" -eq 0 ]
    [ "$output" == "hello: world" ]

    run _deploying_convert_args_to_yaml --hello=world --old man --young "boy or girl"
    [ "$status" -eq 0 ]
    expected=$(cat <<EOF
hello: world
old: man
young: "boy or baby"
EOF
    )
    [ "$output" == "$expected" ]

}

@test "_deploying_convert_args_to_yaml function handles short form switches" {
    run _deploying_convert_args_to_yaml -h world
    [ "$status" -eq 0 ]
    [ "$output" == "h: world" ]

    run _deploying_convert_args_to_yaml -h="world"
    [ "$status" -eq 0 ]
    [ "$output" == "h: \"world\"" ]

    run _deploying_convert_args_to_yaml -h=world -o man -y "boy or girl"
    [ "$status" -eq 0 ]
    expected=$(cat <<EOF
h: world
o: man
y: "boy or baby"
EOF
    )
    [ "$output" == "$expected" ]

}

@test "_deploying_convert_args_to_yaml function handles mix and match" {

    run _deploying_convert_args_to_yaml --rpc-url local -x -p k --long-equals=long "
    hello: world
    old: man" --final
    [ "$status" -eq 0 ]

    expected=$(cat <<EOF
rpc-url: local
x: ""
p: k
long-equals: long
hello: world
old: man
final: ""
EOF
    )
    echo "$output"
    echo "$expected"

    [ "$output" == "$expected" ]
}
