scope "/mentee", as: :mentee do
  # Catch-all: react-router (basename="/mentee") owns sub-paths.
  get "(*path)", to: "mentee/pages#index", format: false
end
