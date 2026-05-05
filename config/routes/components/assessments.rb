scope "/assessments", as: :assessments do
  get "(*path)", to: "assessments/pages#index", format: false
end
