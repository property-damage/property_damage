# Golden render of a seeded run set; written by generate.exs, do not edit.
[
  {1,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 16, balance: -31}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -16}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 18
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 9
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 6
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 9
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 18
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }}
     ]
   }},
  {2,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 12, balance: -23}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -12}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 9
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 7
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 7
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 20
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 20
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }}
     ]
   }},
  {3,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 16, balance: -31}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -16}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 20
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 10
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 10
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 18
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 67
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 11
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 10
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 20
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 18
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 67
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 11
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }}
     ]
   }},
  {4,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 13, balance: -25}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -13}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 6
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 18
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 18
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }}
     ]
   }},
  {5,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 13, balance: -25}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -13}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 6
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }}
     ]
   }},
  {6,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 12, balance: -23}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -12}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 14
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 19
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }}
     ]
   }},
  {7,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 14, balance: -27}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -14}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 11
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 6
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 11
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 19
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 14
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }}
     ]
   }},
  {8,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 13, balance: -25}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -13}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 11
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 27
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 11
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 11
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 27
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 11
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }}
     ]
   }},
  {9,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 17, balance: -33}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -17}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 18
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 18
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 19
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 14
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }}
     ]
   }},
  {10,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 13, balance: -25}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -13}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 7
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 14
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }}
       ],
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }}
     ]
   }},
  {11,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 19, balance: -37}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -19}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 20
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }}
       ],
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 20
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 19
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }}
     ]
   }},
  {12,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 20, balance: -39}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -20}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 41
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 6
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 19
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 41
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 14
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 20
        }}
     ]
   }},
  {13,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 14, balance: -27}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -14}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 18
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 29
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 6
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 11
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 10
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 18
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 29
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 11
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }}
     ]
   }},
  {14,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 17, balance: -33}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -17}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 14
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }}
     ]
   }},
  {15,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 23, balance: -45}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -23}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 11
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 6
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 23
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 7
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 11
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 19
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 23
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 23
        }}
     ]
   }},
  {16,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 17, balance: -33}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -17}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 9
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 7
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 6
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 40
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 19
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 40
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }}
     ]
   }},
  {17,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 20, balance: -39}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -20}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 40
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 40
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 20
        }}
     ]
   }},
  {18,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 16, balance: -31}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -16}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 2
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 20
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 9
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 20
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }}
     ]
   }},
  {19,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 14, balance: -27}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -14}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 11
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 4
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 20
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 15
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 14
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 11
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 20
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 14
        }}
     ]
   }},
  {20,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 12, balance: -23}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -12}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 19
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 7
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 20
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 28
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 11
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 18
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }}
       ],
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 19
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 20
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 28
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 12
        }}
     ]
   }},
  {24,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "USD", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 3, balance: 3}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 2, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 1, balance: 0}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 20, balance: 20}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 21}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 7, balance: 28}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 10, balance: 18}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 16, balance: 34}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 17, balance: 51}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "USD", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 12, balance: 12}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 3, balance: 9}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 3, balance: 6}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 7, balance: 13}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 2, balance: 15}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 3, balance: 12}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 9, balance: 21}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 15, balance: 36}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 9, balance: 27}}
     ],
     failure: nil,
     original: nil,
     outcome: :pass,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 20
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }}
       ],
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }}
       ]
     ],
     shrunk: nil
   }},
  {33,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "USD", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 14, balance: 14}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 8, balance: 6}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 3, balance: 9}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 4, balance: 5}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 2, balance: 7}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 6, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 1, balance: 0}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 15, balance: 15}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 3, balance: 12}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "USD", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 16, balance: 16}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 10, balance: 6}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 9, balance: 15}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 7, balance: 8}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 6, balance: 2}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 4, balance: 6}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 4, balance: 2}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 3, balance: 5}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 4, balance: 1}}
     ],
     failure: nil,
     original: nil,
     outcome: :pass,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 14
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 2
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 15
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }}
       ],
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 4
          }}
       ]
     ],
     shrunk: nil
   }},
  {39,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "USD", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 7, balance: 7}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 6, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 1, balance: 0}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 10, balance: 10}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 5, balance: 15}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 8, balance: 7}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 10, balance: 17}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 7, balance: 10}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 6, balance: 4}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "USD", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 7, balance: 7}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 1, balance: 6}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 12, balance: 18}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 5, balance: 23}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 9, balance: 14}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 6, balance: 8}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 1, balance: 7}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 7, balance: 0}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 6, balance: 6}}
     ],
     failure: nil,
     original: nil,
     outcome: :pass,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 10
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }}
       ],
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 12
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 9
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 1
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 7
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 6
          }}
       ]
     ],
     shrunk: nil
   }},
  {40,
   %{
     events: [
       {:command, "PropertyDamage.Test.Gauntlet.Events.AccountOpened",
        %{currency: "", id: "acct-1"}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Deposited",
        %{account_id: "acct-1", amount: 1, balance: 1}},
       {:command, "PropertyDamage.Test.Gauntlet.Events.Withdrawn",
        %{account_id: "acct-1", amount: 16, balance: -31}}
     ],
     failure: %{
       check: :balance_matches_ledger,
       kind: :check_failed,
       message: "Reported balance differs from the ledger: %{drift: -16}",
       root_index: 2
     },
     original: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 17
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 3
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 13
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 5
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 8
        }}
     ],
     outcome: :fail,
     plans: [
       [
         {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: "USD"}},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 17
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 3
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 16
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 13
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 5
          }},
         {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
          %{
            account_id:
              "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
            amount: 8
          }}
       ]
     ],
     shrunk: [
       {"PropertyDamage.Test.Gauntlet.Commands.Open", %{currency: ""}},
       {"PropertyDamage.Test.Gauntlet.Commands.Deposit",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 1
        }},
       {"PropertyDamage.Test.Gauntlet.Commands.Withdraw",
        %{
          account_id:
            "placeholder(PropertyDamage.Test.Gauntlet.Events.AccountOpened, [:id], event 0)",
          amount: 16
        }}
     ]
   }}
]
