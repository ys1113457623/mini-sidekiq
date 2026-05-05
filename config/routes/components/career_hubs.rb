scope "/career-hubs", as: :career_hubs do
  get "(*path)", to: "career_hubs/pages#index", format: false
end
