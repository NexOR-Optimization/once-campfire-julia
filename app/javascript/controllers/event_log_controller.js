import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  log(event) {
    console.log(event)
  }
}
