module.exports = {
    printWidth: 120,
    useTabs: false,
    overrides: [
      {
        files: "*.sol",
        options: {
          semi: true,
          singleQuote: false,
          trailingComma: "all"
        }
      },
      {
        files: "*.json",
        options: {
          tabWidth: 2
        }
      },
      {
        files: [
          "*.ts", "*.tsx"
        ],
        options: {
          arrowParens: "avoid",
          explicitTypes: "preserve",
          semi: true,
          singleQuote: true,
          trailingComma: "all"
        }
      },
      {
        files: [
          "*.yml", "*.yaml"
        ],
        options: {
          parser: "yaml"
        }
      }
    ],
    plugins: [
      "prettier-plugin-solidity"
    ]
  };