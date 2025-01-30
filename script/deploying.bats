#!/usr/bin/env bats

setup() {
    source "bin-modules/logging"
    logging_config debug
    source "script/deploying"
}

@test "_deploying_convert_args_to_yaml function handles YAML" {
    run _deploying_convert_args_to_yaml "hello: world"
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "hello: world" ]

    run _deploying_convert_args_to_yaml "hello:  world"
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "hello: world" ]

    run _deploying_convert_args_to_yaml "hello:world"
    [ "$status" -eq 1 ] # yaml nees a space after the :

    run _deploying_convert_args_to_yaml 'hello:"world"'
    [ "$status" -eq 1 ]

    run _deploying_convert_args_to_yaml '
    hello: world
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
    run _deploying_convert_args_to_yaml --hello=world
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "hello: world" ]

    run _deploying_convert_args_to_yaml --hello="world"
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "hello: world" ]

    run _deploying_convert_args_to_yaml --hello
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "hello: \"\"" ]

    run _deploying_convert_args_to_yaml --hello "world"
    [ "$status" -eq 1 ] # world is not valid YAML

    run _deploying_convert_args_to_yaml --hello "there: world"
    expected=$(cat <<EOF
hello: ""
there: world
EOF
    )
    echo "---output---"
    echo "$output"
    echo "---expected---"
    echo "$expected"
    echo "------"
    [ "$output" == "$expected" ]

    run _deploying_convert_args_to_yaml --hello "world"
    [ "$status" -eq 1 ] # hello is an unlisted arg, so = is needed

    run _deploying_convert_args_to_yaml --hello=world --novalue --young="boy or girl"
    [ "$status" -eq 0 ]
    expected=$(cat <<EOF
hello: world
novalue: ""
young: boy or girl
EOF
    )
    echo "---output---"
    echo "$output"
    echo "---expected---"
    echo "$expected"
    echo "------"
    [ "$output" == "$expected" ]

}

@test "_deploying_convert_args_to_yaml function handles short form switches" {
    run _deploying_convert_args_to_yaml -hello
    [ "$status" -eq 1 ] # short form need a single letter

    run _deploying_convert_args_to_yaml -a=world
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "a: world" ]

    run _deploying_convert_args_to_yaml -a="world"
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "a: world" ]

    run _deploying_convert_args_to_yaml -a
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "a: \"\"" ]

    run _deploying_convert_args_to_yaml -a "world"
    [ "$status" -eq 1 ] # world is not valid YAML

    run _deploying_convert_args_to_yaml -a "there: world"
    expected=$(cat <<EOF
a: ""
there: world
EOF
    )
    echo "---output---"
    echo "$output"
    echo "---expected---"
    echo "$expected"
    echo "------"
    [ "$output" == "$expected" ]

    run _deploying_convert_args_to_yaml -a "world"
    [ "$status" -eq 1 ] # hello is an unlisted arg, so = is needed

    run _deploying_convert_args_to_yaml -a=world -n -y="boy or girl"
    [ "$status" -eq 0 ]
    expected=$(cat <<EOF
a: world
n: ""
y: boy or girl
EOF
    )
    echo "---output---"
    echo "$output"
    echo "---expected---"
    echo "$expected"
    echo "------"
    [ "$output" == "$expected" ]

}

@test "_deploying_convert_args_to_yaml function handles mix and match" {

    run _deploying_convert_args_to_yaml --hello=world "local: true" -x -p "k: x" --long-equals=long "
    hello: there
    old: man" --final
    [ "$status" -eq 0 ]

    expected=$(cat <<EOF
hello: there
local: true
x: ""
p: ""
k: x
long-equals: long
old: man
final: ""
EOF
    )
    echo "---output---"
    echo "$output"
    echo "---expected---"
    echo "$expected"
    echo "------"
    [ "$output" == "$expected" ]
}

@test "_deploying_convert_args_to_yaml function handles known args" {

    # ["rpc-url"]=":"
    # ["verify"]="-"
    # ["logging"]="-:"
    # ["h"]="-"
    # ["help"]="-"

    run _deploying_convert_args_to_yaml --rpc-url local
    [ "$status" -eq 0 ]
    [ "$output" == "rpc-url: local" ]

    run _deploying_convert_args_to_yaml --rpc-url=local
    [ "$status" -eq 0 ]
    [ "$output" == "rpc-url: local" ]

    run _deploying_convert_args_to_yaml --rpc-url
    [ "$status" -eq 1 ]

    run _deploying_convert_args_to_yaml --verify
    [ "$status" -eq 0 ]
    [ "$output" == "verify: \"\"" ]

    run _deploying_convert_args_to_yaml --verify=local
    [ "$status" -eq 1 ]

    run _deploying_convert_args_to_yaml --verify "a: b"
    [ "$status" -eq 0 ]
    expected=$(cat <<EOF
verify: ""
a: b
EOF
    )
    [ "$output" == "$expected" ]


   run _deploying_convert_args_to_yaml --logging local
    [ "$status" -eq 0 ]
    [ "$output" == "logging: local" ]

    run _deploying_convert_args_to_yaml --logging=local
    [ "$status" -eq 0 ]
    [ "$output" == "logging: local" ]

    run _deploying_convert_args_to_yaml --logging
    [ "$status" -eq 0 ]
    [ "$output" == "logging: \"\"" ]


    run _deploying_convert_args_to_yaml -h
    [ "$status" -eq 0 ]
    [ "$output" == "h: \"\"" ]

    run _deploying_convert_args_to_yaml -h=local
    [ "$status" -eq 1 ]

    run _deploying_convert_args_to_yaml -h "a: b"
    [ "$status" -eq 0 ]
    expected=$(cat <<EOF
h: ""
a: b
EOF
    )
    [ "$output" == "$expected" ]

}

@test "_deploying_convert_args_to_yaml function handles weird args" {
    run _deploying_convert_args_to_yaml -a=world=as=one
    [ "$status" -eq 0 ]
    echo "output=$output"
    [ "$output" == "a: world=as=one" ]

}
